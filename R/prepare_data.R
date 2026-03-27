# =============================================================================
# prepare_data.R — Stage 1: Raw CSVs → Processed .rds files
# EU FDI Explorer
#
# Run once (or when new data call arrives).
# Reads Catches (per-year CSVs) + Effort files from DATA_ROOT.
# Saves aggregated .rds files to data/processed/.
# =============================================================================

library(tidyverse)
library(data.table)
library(janitor)

source("R/helpers.R")

# ---- CONFIG ------------------------------------------------------------------
# Set this to wherever your extracted STECF ZIP lives.
# Expects subfolders: Catches/, Effort/

# Auto-detect: if running from eu-fdi-explorer/, go up one level
DATA_ROOT <- normalizePath(file.path(getwd(), ".."), winslash = "/")

# Verify subfolders exist, otherwise try the explicit path
if (!dir.exists(file.path(DATA_ROOT, "Catches"))) {
  DATA_ROOT <- "C:/Users/emant/Downloads/2025_Effort-landings-catches-capacity-biological"
}
stopifnot(
  dir.exists(file.path(DATA_ROOT, "Catches")),
  dir.exists(file.path(DATA_ROOT, "Effort"))
)

OUT_DIR <- "data/processed"
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

cat("DATA_ROOT:", DATA_ROOT, "\n")

# =============================================================================
# 1. CATCHES — per-year CSV files
# =============================================================================

cat("\n=== LOADING CATCHES ===\n")

catches_dir <- file.path(DATA_ROOT, "Catches")
csv_files   <- list.files(catches_dir,
                           pattern = "FDI.*Catches.*\\.csv$",
                           full.names = TRUE)

cat("Found", length(csv_files), "catches CSV files:\n")
cat(paste(" ", basename(csv_files)), sep = "\n")

# Read all as character to handle C values safely, then bind
catches_raw <- csv_files %>%
  map_dfr(~ {
    cat("  Reading:", basename(.x), "\n")
    fread(.x, colClasses = "character", encoding = "Latin-1") %>%
      as_tibble()
  })

cat("Total catches rows:", nrow(catches_raw), "\n")
cat("Columns:", paste(names(catches_raw), collapse = ", "), "\n")

# Catches columns are already snake_case — verify
stopifnot("country" %in% names(catches_raw))
stopifnot("total_live_weight_landed" %in% names(catches_raw))

# ---- Confidentiality diagnostics --------------------------------------------

cat("\n--- Confidentiality check (catches) ---\n")
cat("Unique 'confidential' values:", paste(unique(catches_raw$confidential), collapse = ", "), "\n")

n_total <- nrow(catches_raw)
n_c_landings  <- sum(catches_raw$total_live_weight_landed == "C", na.rm = TRUE)
n_c_value     <- sum(catches_raw$total_value_of_landings == "C", na.rm = TRUE)
n_c_discards  <- sum(catches_raw$tot_discards_tonnes == "C", na.rm = TRUE)

cat(sprintf("  C in landings weight: %d / %d (%.1f%%)\n", n_c_landings, n_total, 100 * n_c_landings / n_total))
cat(sprintf("  C in landings value:  %d / %d (%.1f%%)\n", n_c_value, n_total, 100 * n_c_value / n_total))
cat(sprintf("  C in discards:        %d / %d (%.1f%%)\n", n_c_discards, n_total, 100 * n_c_discards / n_total))

# ---- Convert C → NA + numeric -----------------------------------------------

catches <- catches_raw %>%
  mutate(
    across(c(total_live_weight_landed, total_value_of_landings, tot_discards_tonnes),
           ~ c_to_na(.x)),
    year    = as.integer(year),
    quarter = as.integer(quarter),
    area    = area_group(sub_region)
  )

cat("\nYear range:", range(catches$year), "\n")
cat("Unique areas:", paste(sort(unique(catches$area)), collapse = ", "), "\n")

# ---- C values by area -------------------------------------------------------
cat("\n--- % C (landings weight) by area ---\n")
catches_raw %>%
  mutate(area = area_group(sub_region)) %>%
  group_by(area) %>%
  summarise(
    n = n(),
    pct_c = 100 * mean(total_live_weight_landed == "C", na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(pct_c)) %>%
  print()

# =============================================================================
# 2. EFFORT BY COUNTRY — single CSV
# =============================================================================

cat("\n=== LOADING EFFORT BY COUNTRY ===\n")

effort_file <- file.path(DATA_ROOT, "Effort", "FDI Effort by country.csv")
cat("Reading:", effort_file, "\n")

effort_raw <- fread(effort_file, colClasses = "character", encoding = "Latin-1") %>%
  clean_names() %>%
  as_tibble()

cat("Rows:", nrow(effort_raw), "\n")
cat("Columns after clean_names():\n")
cat(paste(" ", names(effort_raw)), sep = "\n")

# ---- Rename to match catches conventions ------------------------------------
# clean_names() converts "Vessel Length Category" → "vessel_length_category",
# "Fishing Technique" → "fishing_technique", etc.  We align to catches names.

effort <- effort_raw %>%
  rename_with(~ case_when(
    . == "vessel_length_category" ~ "vessel_length",
    . == "fishing_technique"      ~ "fishing_tech",
    . == "target_assemblage"      ~ "target_assemblage",
    . == "mesh_size_range"        ~ "mesh_size_range",
    . == "metier7"                ~ "metier_7",
    . == "supra_region"           ~ "supra_region",
    . == "sub_region"             ~ "sub_region",
    . == "eez_indicator"          ~ "eez_indicator",
    . == "geo_indicator"          ~ "geo_indicator",
    . == "specon_tech"            ~ "specon_tech",
    TRUE ~ .
  ))

cat("\nEffort columns after rename:\n")
cat(paste(" ", names(effort)), sep = "\n")

# ---- Confidentiality diagnostics (effort) ------------------------------------
cat("\n--- Confidentiality check (effort) ---\n")
cat("Unique 'confidential' values:", paste(unique(effort$confidential), collapse = ", "), "\n")

# Identify effort numeric columns (may contain C)
effort_num_cols <- c("total_days_at_sea", "total_fishing_days",
                     "total_k_w_days_at_sea", "total_gt_days_at_sea",
                     "total_k_w_fishing_days", "total_gt_fishing_days",
                     "hours_at_sea", "k_w_hours_at_sea", "gt_hours_at_sea")

# Check which columns actually exist (clean_names may produce slightly different names)
effort_num_cols_present <- intersect(effort_num_cols, names(effort))
cat("Numeric effort columns found:", paste(effort_num_cols_present, collapse = ", "), "\n")

# If clean_names produced different names, find the actual effort metric columns
if (length(effort_num_cols_present) == 0) {
  cat("WARNING: Expected effort columns not found. Checking all columns for C values...\n")
  # Find columns containing C values (likely the numeric effort metrics)
  has_c <- sapply(effort, function(col) any(col == "C", na.rm = TRUE))
  effort_num_cols_present <- names(has_c)[has_c]
  cat("Columns with C values:", paste(effort_num_cols_present, collapse = ", "), "\n")
}

for (col in effort_num_cols_present) {
  nc <- sum(effort[[col]] == "C", na.rm = TRUE)
  cat(sprintf("  C in %-30s: %d / %d (%.1f%%)\n",
              col, nc, nrow(effort), 100 * nc / nrow(effort)))
}

# ---- Convert C → NA + numeric -----------------------------------------------
effort <- effort %>%
  mutate(
    across(all_of(effort_num_cols_present), ~ c_to_na(.x)),
    year    = as.integer(year),
    quarter = as.integer(quarter),
    area    = area_group(sub_region)
  )

cat("\nEffort year range:", range(effort$year), "\n")

# =============================================================================
# 3. EFFORT EU — single CSV (no C values)
# =============================================================================

cat("\n=== LOADING EFFORT EU ===\n")

effort_eu_file <- file.path(DATA_ROOT, "Effort", "FDI Effort EU.csv")
cat("Reading:", effort_eu_file, "\n")

effort_eu_raw <- fread(effort_eu_file, colClasses = "character", encoding = "Latin-1") %>%
  clean_names() %>%
  as_tibble()

cat("Rows:", nrow(effort_eu_raw), "\n")
cat("Columns after clean_names():\n")
cat(paste(" ", names(effort_eu_raw)), sep = "\n")

# Same rename as effort by country
effort_eu <- effort_eu_raw %>%
  rename_with(~ case_when(
    . == "vessel_length_category" ~ "vessel_length",
    . == "fishing_technique"      ~ "fishing_tech",
    . == "metier7"                ~ "metier_7",
    TRUE ~ .
  ))

# Identify numeric columns in effort_eu (should be clean — no C values)
effort_eu_num_cols <- intersect(effort_num_cols, names(effort_eu))
if (length(effort_eu_num_cols) == 0) {
  # Fallback: find columns that look numeric
  effort_eu_num_cols <- names(effort_eu)[sapply(effort_eu, function(col) {
    all(is.na(col) | str_detect(col, "^-?[0-9]"))
  })]
  # Exclude known character columns
  effort_eu_num_cols <- setdiff(effort_eu_num_cols, c("year", "quarter"))
}
cat("Effort EU numeric columns:", paste(effort_eu_num_cols, collapse = ", "), "\n")

effort_eu <- effort_eu %>%
  mutate(
    across(all_of(effort_eu_num_cols), ~ as.numeric(.x)),
    year    = as.integer(year),
    quarter = as.integer(quarter),
    area    = area_group(sub_region)
  )

cat("Effort EU year range:", range(effort_eu$year), "\n")
cat("Country values:", paste(unique(effort_eu$country), collapse = ", "), "\n")

# =============================================================================
# 4. CONFIDENTIALITY DIAGNOSTICS TABLE
# =============================================================================

cat("\n=== BUILDING CONFIDENTIALITY DIAGNOSTICS ===\n")

# ---- 4.0a Catches: % C by country × variable × area × year ------------------
conf_catches <- catches_raw %>%
  mutate(area = area_group(sub_region),
         year = as.integer(year)) %>%
  group_by(country, area, year) %>%
  summarise(
    n_total      = n(),
    n_c_landings = sum(total_live_weight_landed == "C", na.rm = TRUE),
    n_c_value    = sum(total_value_of_landings == "C", na.rm = TRUE),
    n_c_discards = sum(tot_discards_tonnes == "C", na.rm = TRUE),
    .groups = "drop"
  )

# ---- 4.0b Effort: % C by country × area × year ------------------------------
# We need pre-conversion effort data — use effort_raw (before C→NA) with renamed cols
conf_effort <- effort_raw %>%
  rename_with(~ case_when(
    . == "vessel_length_category" ~ "vessel_length",
    . == "fishing_technique"      ~ "fishing_tech",
    . == "metier7"                ~ "metier_7",
    TRUE ~ .
  )) %>%
  mutate(area = area_group(sub_region),
         year = as.integer(year)) %>%
  group_by(country, area, year) %>%
  summarise(
    n_total        = n(),
    n_c_fish_days  = sum(total_fishing_days == "C", na.rm = TRUE),
    n_c_kw_days    = sum(total_k_w_days_at_sea == "C", na.rm = TRUE),
    .groups = "drop"
  )

conf_diag <- list(catches = conf_catches, effort = conf_effort)
saveRDS(conf_diag, file.path(OUT_DIR, "conf_diagnostics.rds"))
cat("  Saved: conf_diagnostics.rds\n")

# =============================================================================
# 5. LO EXEMPTIONS — STECF EWG 25-10 Annex 3
# =============================================================================

cat("\n=== LOADING LO EXEMPTIONS (Annex 3) ===\n")

exemptions_file <- "data/raw/STECF_EWG_25-10_Annex3_Exemptions.xlsx"

if (file.exists(exemptions_file)) {
  library(readxl)

  # Sheet → region_label mapping
  exemption_sheets <- c(
    "Baltic Sea" = "Baltic Sea",
    "North Sea"  = "North Sea",
    "NWW"        = "NW Waters",
    "SWW"        = "SW Waters",
    "Med Sea"    = "Mediterranean"
  )

  read_exemption_sheet <- function(sheet_name, region_label) {
    df <- read_excel(exemptions_file, sheet = sheet_name, col_names = FALSE, skip = 2,
                      col_types = "text")

    # Column mapping (consistent across all 5 sheets):
    # 1=blank, 2=exemption_type, 3=article, 4=area, 5=gear_code, 6=mesh_size,
    # 7=vessel_length, 8=special_conditions, 9=target_assemblage, 10=species,
    # 11=year, 12=country, 13=landings_tonnes,
    # 14=discards_ms, 15=landings_w_discards_ms, 16=coverage_ms, 17=discard_rate_ms,
    # 18=discards_fillin, 19=landings_w_discards_fillin, 20=coverage_fillin, 21=discard_rate_fillin

    # Header row is row 1 after skip=2, data starts row 2+
    # Row 1 is the sub-header row ("Discards, tonnes | Landings with discards...")
    # Actual data starts from row 2
    df <- df[-1, ]  # remove the sub-header row

    ncols <- ncol(df)
    # Assign consistent names
    base_names <- c("blank", "exemption_type", "article", "area_detail",
                    "gear_code", "mesh_size", "vessel_length", "special_conditions",
                    "target_assemblage", "species", "year", "country", "landings_tonnes")

    ms_names <- c("discards_ms", "landings_w_discards_ms", "coverage_ms", "discard_rate_ms")
    fillin_names <- c("discards_fillin", "landings_w_discards_fillin", "coverage_fillin", "discard_rate_fillin")

    all_names <- c(base_names, ms_names, fillin_names)
    # Some sheets (NWW) have extra columns — truncate or pad
    if (ncols >= length(all_names)) {
      names(df)[1:length(all_names)] <- all_names
      df <- df[, 1:length(all_names)]
    } else {
      names(df)[1:ncols] <- all_names[1:ncols]
    }

    df <- df %>%
      select(-blank) %>%
      # Remove "Total exemption" summary rows and header leftovers
      filter(is.na(country) | country != "Total exemption") %>%
      filter(!is.na(species) & species != "NA") %>%
      filter(is.na(exemption_type) | !str_detect(tolower(exemption_type), "^type of")) %>%
      # Fill down merged cells
      fill(exemption_type, article, area_detail, .direction = "down") %>%
      mutate(
        region = region_label,
        # Convert n.a. → NA, then numeric
        across(c(landings_tonnes, starts_with("discards_"), starts_with("landings_w_"),
                 starts_with("coverage_"), starts_with("discard_rate_")),
               ~ {
                 x <- as.character(.x)
                 x <- ifelse(x %in% c("n.a.", "n.a", "c", "C", "NA"), NA_character_, x)
                 as.numeric(x)
               }),
        year = as.integer(as.character(year)),
        # Standardise exemption type
        exemption_type = case_when(
          str_detect(tolower(exemption_type), "deminimis|de minimis|de_minimis") ~ "De minimis",
          str_detect(tolower(exemption_type), "surviv|survav")                   ~ "Survivability",
          str_detect(tolower(exemption_type), "^20\\d\\d/")                      ~ "Survivability",
          TRUE ~ as.character(exemption_type)
        )
      )

    df
  }

  lo_exemptions <- imap_dfr(exemption_sheets, ~ read_exemption_sheet(.y, .x))

  cat("lo_exemptions:", nrow(lo_exemptions), "rows\n")
  cat("Regions:", paste(unique(lo_exemptions$region), collapse = ", "), "\n")
  cat("Exemption types:", paste(unique(lo_exemptions$exemption_type), collapse = ", "), "\n")
  cat("Species:", n_distinct(lo_exemptions$species), "unique\n")
  cat("Countries:", n_distinct(lo_exemptions$country), "unique\n")

  saveRDS(lo_exemptions, file.path(OUT_DIR, "lo_exemptions.rds"))
  cat("  Saved: lo_exemptions.rds\n")
} else {
  cat("WARNING: Exemptions file not found at", exemptions_file, "\n")
  cat("  Skipping lo_exemptions.rds — Section 5.4 exemption plots will be unavailable\n")
}

# =============================================================================
# 6. AGGREGATE & SAVE .rds FILES
# =============================================================================

cat("\n=== AGGREGATING & SAVING ===\n")

# ---- 5a. Catches by area × year × gear × species ----------------------------
# Keep row-level detail needed for sections 3-5
catches_agg <- catches %>%
  group_by(area, sub_region, country, year, quarter,
           fishing_tech, gear_type, target_assemblage, metier,
           vessel_length, species) %>%
  summarise(
    landings_wt  = sum(total_live_weight_landed, na.rm = TRUE),
    landings_val = sum(total_value_of_landings, na.rm = TRUE),
    discards_wt  = sum(tot_discards_tonnes, na.rm = TRUE),
    n_records    = n(),
    n_c_landings = sum(is.na(total_live_weight_landed)),
    n_c_discards = sum(is.na(tot_discards_tonnes)),
    .groups = "drop"
  )

cat("catches_agg:", nrow(catches_agg), "rows\n")
saveRDS(catches_agg, file.path(OUT_DIR, "catches_by_area_year_gear_species.rds"))
cat("  Saved: catches_by_area_year_gear_species.rds\n")

# ---- 5b. Effort by area × year × gear (by country) --------------------------
effort_agg <- effort %>%
  group_by(area, sub_region, country, year, quarter,
           fishing_tech, gear_type, target_assemblage, metier,
           vessel_length) %>%
  summarise(
    across(all_of(effort_num_cols_present),
           ~ sum(.x, na.rm = TRUE),
           .names = "{.col}"),
    n_records = n(),
    .groups = "drop"
  )

cat("effort_agg:", nrow(effort_agg), "rows\n")
saveRDS(effort_agg, file.path(OUT_DIR, "effort_by_area_year_gear.rds"))
cat("  Saved: effort_by_area_year_gear.rds\n")

# ---- 5c. Effort EU by area × year × gear (clean, no C) ----------------------
effort_eu_agg <- effort_eu %>%
  group_by(area, sub_region, country, year, quarter,
           fishing_tech, gear_type, target_assemblage, metier,
           vessel_length) %>%
  summarise(
    across(all_of(effort_eu_num_cols),
           ~ sum(.x, na.rm = TRUE),
           .names = "{.col}"),
    n_records = n(),
    .groups = "drop"
  )

cat("effort_eu_agg:", nrow(effort_eu_agg), "rows\n")
saveRDS(effort_eu_agg, file.path(OUT_DIR, "effort_eu_by_area_year_gear.rds"))
cat("  Saved: effort_eu_by_area_year_gear.rds\n")

# ---- 5d. Effort by country × year × métier (for clustering) -----------------
effort_metier <- effort %>%
  filter(area == "Mediterranean & Black Sea") %>%
  group_by(country, year, fishing_tech, gear_type, target_assemblage) %>%
  summarise(
    across(all_of(effort_num_cols_present),
           ~ sum(.x, na.rm = TRUE),
           .names = "{.col}"),
    n_records = n(),
    .groups = "drop"
  )

cat("effort_metier (Med only):", nrow(effort_metier), "rows\n")
saveRDS(effort_metier, file.path(OUT_DIR, "effort_by_country_year_metier.rds"))
cat("  Saved: effort_by_country_year_metier.rds\n")

# =============================================================================
# 7. SUMMARY
# =============================================================================

cat("\n=== DONE ===\n")
cat("Output files in", OUT_DIR, ":\n")
for (f in list.files(OUT_DIR, pattern = "\\.rds$")) {
  sz <- file.size(file.path(OUT_DIR, f))
  cat(sprintf("  %-50s  %s\n", f, format(sz, big.mark = ",")))
}

cat("\nCatches: ", nrow(catches), "rows,", n_distinct(catches$year), "years,",
    n_distinct(catches$country), "countries,", n_distinct(catches$species), "species\n")
cat("Effort:  ", nrow(effort), "rows,", n_distinct(effort$year), "years,",
    n_distinct(effort$country), "countries\n")
cat("Effort EU:", nrow(effort_eu), "rows,", n_distinct(effort_eu$year), "years\n")

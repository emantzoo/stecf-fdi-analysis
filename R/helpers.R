# =============================================================================
# helpers.R — Theme, palettes, area grouping, utility functions
# EU FDI Explorer
# =============================================================================

library(tidyverse)
library(scales)
library(paletteer)

# ---- ggplot2 theme -----------------------------------------------------------

theme_fdi <- function(base_size = 12) {
  theme_minimal(base_size = base_size) +
    theme(
      plot.title       = element_text(face = "bold", size = rel(1.2)),
      plot.subtitle    = element_text(colour = "grey40", size = rel(0.9)),
      plot.caption     = element_text(colour = "grey50", size = rel(0.7), hjust = 0),
      panel.grid.minor = element_blank(),
      strip.text       = element_text(face = "bold"),
      legend.position  = "bottom"
    )
}

# ---- Colour palettes --------------------------------------------------------

# Categorical (many groups): glasbey from pals
pal_cat <- function(n = 32) {
  paletteer::paletteer_d("pals::glasbey", n = n)
}

# Fewer categories: a curated 8-colour palette
pal_area <- c(
  "Mediterranean & Black Sea" = "#E64B35",
  "North Sea & Eastern Arctic" = "#4DBBD5",
  "Baltic Sea"                 = "#00A087",
  "Atlantic (Western Waters)"  = "#3C5488",
  "Other / Distant waters"     = "#B09C85"
)

pal_gear <- c(
  "OTB" = "#E64B35", "OTT" = "#F39B7F", "TBB" = "#DC0000",
  "GNS" = "#4DBBD5", "GTR" = "#91D1C2",
  "LLS" = "#00A087", "PS"  = "#3C5488",
  "FPO" = "#B09C85", "PMP" = "#7E6148",
  "Other" = "#CCCCCC"
)

# ---- Area grouping function --------------------------------------------------

area_group <- function(sub_region) {
  case_when(
    str_detect(sub_region, "^GSA")                                   ~ "Mediterranean & Black Sea",
    sub_region == "BSA"                                              ~ "Mediterranean & Black Sea",
    str_starts(sub_region, "37\\.")                                  ~ "Mediterranean & Black Sea",
    str_detect(sub_region, "^27\\.(1|2|3\\.a|4)")                    ~ "North Sea & Eastern Arctic",
    str_detect(sub_region, "^27\\.3\\.[b-d]")                        ~ "Baltic Sea",
    str_detect(sub_region, "^27\\.(5|6|7|8|9|10)")                   ~ "Atlantic (Western Waters)",
    TRUE                                                             ~ "Other / Distant waters"
  )
}

# ---- Utility functions -------------------------------------------------------

# Convert C (confidential) to NA, then to numeric
c_to_na <- function(x) {
  as.numeric(ifelse(x == "C", NA_character_, x))
}

# Discard ratio: discards / (landings + discards)
discard_ratio <- function(discards, landings) {
  total <- landings + discards
  ifelse(is.na(total) | total == 0, NA_real_, discards / total)
}

# Format thousands with comma separator
fmt_thousands <- function(x) {
  scales::comma(x, accuracy = 1)
}

# Clean ggplotly: remove modebar clutter
ggplotly_clean <- function(p, ...) {
  plotly::ggplotly(p, ...) %>%
    plotly::config(displayModeBar = FALSE) %>%
    plotly::layout(
      hoverlabel = list(bgcolor = "white", font = list(size = 11)),
      margin     = list(t = 50)
    )
}

# Policy milestones for annotation
policy_milestones <- tibble::tribble(
  ~year, ~label,
  2015,  "LO phase-in starts",
  2019,  "West Med MAP",
  2025,  "FMSY targets binding"
)

# ---- Landing Obligation phasing lookup table ---------------------------------
# Based on EU Regulation 1380/2013 Art. 15 and delegated/implementing acts.
# Each row: species codes subject to LO from `year_from` in given area pattern.

lo_phases <- tibble::tribble(
  ~phase,                ~year_from, ~area_pattern,                  ~species,
  "Pelagic",             2015L,      ".*",                           "HER",
  "Pelagic",             2015L,      ".*",                           "MAC",
  "Pelagic",             2015L,      ".*",                           "HOM",
  "Pelagic",             2015L,      ".*",                           "SPR",
  "Pelagic",             2015L,      ".*",                           "WHB",
  "Pelagic",             2015L,      ".*",                           "BOC",
  "Pelagic",             2015L,      ".*",                           "ARG",
  "Pelagic",             2015L,      ".*",                           "PIL",
  "Pelagic",             2015L,      ".*",                           "ANE",
  "Baltic demersal",     2015L,      "Baltic Sea",                   "COD",
  "Baltic demersal",     2015L,      "Baltic Sea",                   "SAL",
  "North Sea demersal",  2016L,      "North Sea & Eastern Arctic",   "HAD",
  "North Sea demersal",  2016L,      "North Sea & Eastern Arctic",   "PLE",
  "North Sea demersal",  2016L,      "North Sea & Eastern Arctic",   "PRA",
  "North Sea demersal",  2016L,      "North Sea & Eastern Arctic",   "NEP",
  "North Sea demersal",  2016L,      "North Sea & Eastern Arctic",   "SOL",
  "North Sea demersal",  2016L,      "North Sea & Eastern Arctic",   "HKE",
  "NW Waters demersal",  2016L,      "Atlantic \\(Western Waters\\)","HAD",
  "NW Waters demersal",  2016L,      "Atlantic \\(Western Waters\\)","NEP",
  "NW Waters demersal",  2016L,      "Atlantic \\(Western Waters\\)","HKE",
  "Med demersal pilot",  2017L,      "Mediterranean & Black Sea",    "HKE",
  "Med demersal pilot",  2017L,      "Mediterranean & Black Sea",    "MUT",
  "Med demersal pilot",  2017L,      "Mediterranean & Black Sea",    "MUR",
  "Med demersal pilot",  2017L,      "Mediterranean & Black Sea",    "SOL",
  "Med demersal pilot",  2017L,      "Mediterranean & Black Sea",    "DPS",
  "Med full",            2019L,      "Mediterranean & Black Sea",    "BSS",
  "Med full",            2019L,      "Mediterranean & Black Sea",    "SBG",
  "Med full",            2019L,      "Mediterranean & Black Sea",    "SBR",
  "Med full",            2019L,      "Mediterranean & Black Sea",    "SBX",
  "Med full",            2019L,      "Mediterranean & Black Sea",    "GPD",
  "Med full",            2019L,      "Mediterranean & Black Sea",    "NEP"
)

# Classify a record as LO-covered based on species, area, year
lo_covered <- function(species, area, year) {
  # Build a fast lookup: for each species × area pattern, earliest LO year
  res <- rep(FALSE, length(species))
  for (i in seq_len(nrow(lo_phases))) {
    match_sp   <- species == lo_phases$species[i]
    match_area <- str_detect(area, lo_phases$area_pattern[i])
    match_yr   <- year >= lo_phases$year_from[i]
    res <- res | (match_sp & match_area & match_yr)
  }
  res
}

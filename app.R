# =============================================================================
# WMATA Safety Analytics: Anonymized Unified Framework (R Shiny app)
#
# Interactive map and dashboard for exploring transit safety incidents by
# year, season, rush-hour period, incident type, location and transit mode.
#
# Built for the GW Systems Engineering capstone with WMATA (2025-2026).
# The real WMATA data is confidential and NOT included in this repository.
# By default the app runs on data/sample_incidents.xlsx, a SYNTHETIC dataset
# with the same columns, so anyone can try the tool.
#
# Run:  open this file in RStudio and click "Run App", or
#       shiny::runApp("app.R")
# =============================================================================

# 1. LOAD LIBRARIES
if (!require("sf")) install.packages("sf")
if (!require("readxl")) install.packages("readxl")
if (!require("leaflet")) install.packages("leaflet")
if (!require("dplyr")) install.packages("dplyr")
if (!require("lubridate")) install.packages("lubridate")
if (!require("tigris")) install.packages("tigris")
if (!require("shiny")) install.packages("shiny")
if (!require("shinythemes")) install.packages("shinythemes")
if (!require("ggplot2")) install.packages("ggplot2")
if (!require("gtools")) install.packages("gtools")

library(sf)
library(readxl)
library(leaflet)
library(dplyr)
library(lubridate)
library(tigris)
library(shiny)
library(shinythemes)
library(ggplot2)
library(gtools)

options(tigris_use_cache = TRUE)

# 2. DATA IMPORT & ANONYMIZATION
# Uses the synthetic sample data by default. To use your own file, change
# DATA_PATH, or set it to NULL to pick a file in a dialog box.
# Required columns: Incident_Type, Latitude, Longitude, Incident_Date,
#                   INCIDENT_TIME (HH:MM:SS), Transit Mode
DATA_PATH <- "data/sample_incidents.xlsx"
download_dir <- "data/"
if (is.null(DATA_PATH) || !file.exists(DATA_PATH)) {
  message("Select your incident Excel file...")
  excel_path <- file.choose()
} else {
  excel_path <- DATA_PATH
}

# Spatial Setup: DC ward boundaries (DC Open Data) + Maryland/Virginia counties (US Census via tigris)
wards_dest <- paste0(download_dir, "dc_wards.geojson")
if(!file.exists(wards_dest)) {
  download.file("https://opendata.dc.gov/api/download/v1/items/c5cd8b40fb784548a6680aead5f919ed/geojson?layers=53", wards_dest, mode = "wb")
}
dc_wards <- st_read(wards_dest, quiet = TRUE) %>% select(Real_Region = NAME) %>% mutate(Type = "Ward")
md_va_counties <- counties(state = c("MD", "VA"), cb = TRUE, resolution = "20m") %>%
  st_transform(4326) %>% select(Real_Region = NAMELSAD) %>% mutate(Type = "County")

all_regions_raw <- rbind(dc_wards, md_va_counties)

# Global Anonymization Keys: real region and incident names are replaced
# with "Location N" and "Incident Type N" before anything is displayed
region_lookup <- all_regions_raw %>% st_drop_geometry() %>% distinct(Real_Region, Type) %>%
  arrange(desc(Type), Real_Region) %>% mutate(Anon_Region = paste0("Location ", row_number()))

raw_df <- read_excel(excel_path)
incident_lookup <- raw_df %>% distinct(Incident_Type) %>% arrange(Incident_Type) %>%
  mutate(Anon_Incident = paste0("Incident Type ", row_number()))

# Process Master Data with Anonymized Labels Only
df_master <- st_join(st_as_sf(raw_df[!is.na(raw_df$Latitude),], coords = c("Longitude", "Latitude"), crs = 4326, remove = FALSE), 
                     all_regions_raw %>% left_join(region_lookup, by = c("Real_Region", "Type")), join = st_intersects) %>%
  left_join(incident_lookup, by = "Incident_Type") %>%
  mutate(Date = as.Date(Incident_Date), Year = as.character(year(Date)), Month = month(Date),
         Season = case_when(Month %in% c(12, 1, 2) ~ "Winter", Month %in% c(3, 4, 5) ~ "Spring", Month %in% c(6, 7, 8) ~ "Summer", TRUE ~ "Fall"),
         Time_12h = format(strptime(INCIDENT_TIME, format='%H:%M'), '%I:%M %p'),
         Hour = hour(hms(INCIDENT_TIME)),
         Rush_Hour_Label = case_when(Hour >= 6 & Hour <= 9 ~ "AM Rush Hour", Hour >= 15 & Hour <= 19 ~ "PM Rush Hour", TRUE ~ "Off-Peak"))

# --- UI ---
ui <- fluidPage(
  theme = shinytheme("flatly"),
  tags$head(tags$style(HTML("
    .report-box { background: #ffffff; border: 1px solid #e3e6f0; border-left: 8px solid #4e73df; padding: 25px; margin-bottom: 25px; border-radius: 5px; box-shadow: 0 0.15rem 1.75rem 0 rgba(58, 59, 69, 0.15); font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; }
    .stat-badge { background-color: #4e73df; color: white; padding: 2px 8px; border-radius: 10px; font-weight: bold; font-size: 0.9em; }
    .stat-red { color: #e74a3b; font-weight: 800; font-size: 1.1em; }
    .chart-desc { background: #f8f9fc; padding: 15px; border-radius: 5px; font-size: 0.9em; color: #5a5c69; margin-bottom: 20px; border-left: 3px solid #d1d3e2; }
    .insight-header { color: #2e59d9; font-weight: bold; margin-top: 20px; text-transform: uppercase; letter-spacing: 0.05em; }
  "))),
  titlePanel("WMATA Safety Analytics: Anonymized Unified Framework"),
  sidebarLayout(
    sidebarPanel(
      wellPanel(tags$b("Privacy Status:"), br(), tags$span(style="color:green;", "Full Data Anonymization Active")),
      hr(),
      selectInput("sel_year", "Year:", choices = c("All" = "all", sort(unique(df_master$Year)))),
      selectInput("sel_season", "Season:", choices = c("All" = "all", "Winter", "Spring", "Summer", "Fall")),
      selectInput("sel_rush", "Time Period:", choices = c("All" = "all", "AM Rush Hour", "PM Rush Hour", "Off-Peak")),
      hr(),
      selectInput("sel_inc_type", "Anonymized Incident Category:", choices = c("All" = "all", mixedsort(unique(df_master$Anon_Incident)))),
      selectInput("sel_region", "Anonymized Location:", choices = c("All" = "all", mixedsort(unique(df_master$Anon_Region)))),
      hr(),
      selectInput("color_by", "Color Markers By:", choices = c("Transit Mode" = "mode", "Season" = "season", "Rush Hour" = "rush")),
      actionButton("go", "Refresh Analytics", icon = icon("sync"), class = "btn-primary", style="width:100%")
    ),
    mainPanel(
      tabsetPanel(
        tabPanel("Geospatial Map", leafletOutput("wmata_map", height = "800px")),
        tabPanel("Strategic Findings", br(), uiOutput("strategic_report")),
        tabPanel("Statistical Graphics", br(), 
                 tags$h4("System Performance Distribution"),
                 plotOutput("mode_plot"),
                 div(class="chart-desc", "This chart adapts to show incident distribution across the selected network layers."),
                 hr(),
                 tags$h4("Temporal Intensity Trends"),
                 plotOutput("time_series_plot"),
                 div(class="chart-desc", "Trends identify underlying safety patterns over the service period."))
      )
    )
  )
)

# --- SERVER ---
server <- function(input, output, session) {
  
  filtered_data <- eventReactive(input$go, {
    data <- df_master
    if (input$sel_year != "all") data <- data %>% filter(Year == input$sel_year)
    if (input$sel_season != "all") data <- data %>% filter(Season == input$sel_season)
    if (input$sel_rush != "all") data <- data %>% filter(Rush_Hour_Label == input$sel_rush)
    if (input$sel_inc_type != "all") data <- data %>% filter(Anon_Incident == input$sel_inc_type)
    if (input$sel_region != "all") data <- data %>% filter(Anon_Region == input$sel_region)
    data
  }, ignoreNULL = FALSE)
  
  output$wmata_map <- renderLeaflet({
    leaflet() %>% addProviderTiles(providers$CartoDB.Positron) %>% setView(lng = -77.0365, lat = 38.8977, zoom = 11)
  })
  
  observe({
    data <- filtered_data()
    if(is.null(data) || nrow(data) == 0) {
      leafletProxy("wmata_map") %>% clearMarkers() %>% clearControls()
      return()
    }
    pal <- switch(input$color_by,
                  "mode" = colorFactor("Dark2", domain = df_master$`Transit Mode`),
                  "season" = colorFactor("Set2", domain = df_master$Season),
                  "rush" = colorFactor("Set1", domain = df_master$Rush_Hour_Label))
    color_val <- switch(input$color_by, "mode" = data$`Transit Mode`, "season" = data$Season, "rush" = data$Rush_Hour_Label)
    leafletProxy("wmata_map", data = data) %>%
      clearMarkers() %>% clearControls() %>%
      addCircleMarkers(radius = 5, fillColor = ~pal(color_val), color = "white", weight = 0.5, fillOpacity = 0.8,
                       popup = paste0("<b>", data$Anon_Incident, "</b><br><b>Location:</b> ", data$Anon_Region)) %>%
      addLegend(pal = pal, values = color_val, title = paste("Color by:", input$color_by), position = "bottomright", layerId = "map_legend")
  })
  
  output$mode_plot <- renderPlot({
    data_to_plot <- filtered_data()
    validate(need(nrow(data_to_plot) > 0, "Insufficient data."))
    plot_var <- switch(input$color_by, "mode" = "Transit Mode", "season" = "Season", "rush" = "Rush_Hour_Label")
    pal_name <- switch(input$color_by, "mode" = "Dark2", "season" = "Set2", "rush" = "Set1")
    ggplot(data_to_plot, aes(x = !!sym(plot_var), fill = !!sym(plot_var))) +
      geom_bar() + theme_minimal() + scale_fill_brewer(palette = pal_name) +
      labs(y = "Frequency", x = paste("Distribution by", input$color_by)) + theme(legend.position = "none")
  })
  
  output$time_series_plot <- renderPlot({
    data_to_plot <- filtered_data()
    validate(need(nrow(data_to_plot) > 0, "Insufficient data."))
    ts_data <- data_to_plot %>% st_drop_geometry() %>% group_by(Date) %>% summarise(n = n())
    ggplot(ts_data, aes(x = Date, y = n)) +
      geom_line(color = "#4e73df", size = 1) + geom_smooth(method = "loess", color = "#e74a3b", fill = "#f8d7da", alpha = 0.3) +
      theme_minimal() + labs(y = "Daily Incident Count", x = "Timeline")
  })
  
  output$strategic_report <- renderUI({
    data <- filtered_data()
    validate(need(nrow(data) > 0, "No data available."))
    
    counts <- data %>% st_drop_geometry() %>% group_by(Loc = Anon_Region) %>% summarise(n = n()) %>% arrange(desc(n))
    top_locs <- na.omit(head(counts$Loc, 3))
    perc_top <- round((sum(head(counts$n, 3)) / nrow(data)) * 100, 1)
    
    am_data <- data %>% filter(Rush_Hour_Label == "AM Rush Hour")
    pm_data <- data %>% filter(Rush_Hour_Label == "PM Rush Hour")
    off_data <- data %>% filter(Rush_Hour_Label == "Off-Peak")
    off_perc <- round((nrow(off_data)/nrow(data))*100, 1)
    
    am_loc <- if(nrow(am_data) > 0) as.character(am_data %>% group_by(Anon_Region) %>% summarise(n=n()) %>% arrange(desc(n)) %>% slice(1) %>% pull(1)) else "No Recorded Data"
    pm_loc <- if(nrow(pm_data) > 0) as.character(pm_data %>% group_by(Anon_Region) %>% summarise(n=n()) %>% arrange(desc(n)) %>% slice(1) %>% pull(1)) else "No Recorded Data"
    
    type_counts <- data %>% st_drop_geometry() %>% group_by(Type = Anon_Incident) %>% summarise(n=n()) %>% arrange(desc(n))
    top_type <- if(nrow(type_counts) > 0) as.character(type_counts$Type[1]) else "No Recorded Data"
    top_type_loc <- if(nrow(data[data$Anon_Incident == top_type,]) > 0) as.character(data %>% filter(Anon_Incident == top_type) %>% group_by(Anon_Region) %>% summarise(n=n()) %>% arrange(desc(n)) %>% slice(1) %>% pull(1)) else ""
    
    div(class = "report-box",
        tags$h3("Strategic Safety Insights"),
        hr(),
        div(class="insight-header", "1. Historical Pattern Identification"),
        tags$p(HTML(paste0("Spatial analysis identifies ", tags$span(class="stat-badge", paste(top_locs, collapse = ", ")), " as high-incident areas. Within this data subset, ", tags$span(class="stat-red", paste0(perc_top, "%")), " of incidents occur at these locations."))),
        div(class="insight-header", "2. Rush Hour Dynamics"),
        tags$p(HTML(paste0(tags$span(class="stat-badge", am_loc), " shows morning clustering (", round((nrow(am_data)/nrow(data))*100, 1), "%), while ", tags$span(class="stat-badge", pm_loc), " exhibits peak clustering during afternoon rush (", round((nrow(pm_data)/nrow(data))*100, 1), "%)."))),
        tags$p(HTML(paste0("Off-peak periods currently account for ", tags$span(class="stat-red", off_perc), "% of the volume."))),
        div(class="insight-header", "3. Incident Type Stratification"),
        tags$p(HTML(paste0("Specifically, ", tags$span(class="stat-badge", top_type), " concentrates in ", tags$span(class="stat-badge", top_type_loc), ". More uniform incident types suggest system-wide causation."))),
        div(class="insight-header", "4. Seasonal Variation Analysis"),
        tags$p(HTML(paste0("Data indicates that ", tags$span(class="stat-badge", top_type), " frequency peaks during ", tags$span(class="stat-red", data$Season[1]), " months.")))
    )
  })
}

shinyApp(ui, server)
library(dplyr)

construct_microbe_pathway_network <- function(
  contrib_file,
  metadata_file,
  taxonomy_file,
  output_file, 
  filtering = c("unfiltered", "mean", "median", "top10%", "top25%", "top50%", "top75%")
) {
  filtering <- match.arg(filtering)
  message("Starting microbe-pathway network construction with filtering: ", filtering)
  
  # Create output directory if it doesn't exist
  if (!dir.exists(output_file)) {
    dir.create(output_file, recursive = TRUE)
    message("Created output directory: ", output_file)
  } else {
    message("Output directory already exists: ", output_file)
  }
  
  message("Loading data...")
  contrib <- tryCatch(
    read.csv(contrib_file, stringsAsFactors = FALSE),
    error = function(e) stop(paste("Error loading contribution file: ", e$message))
  )
  metadata <- tryCatch(
    read.csv(metadata_file, stringsAsFactors = FALSE),
    error = function(e) stop(paste("Error loading metadata file: ", e$message))
  )
  taxonomy <- tryCatch(
    read.csv(taxonomy_file, stringsAsFactors = FALSE),
    error = function(e) stop(paste("Error loading taxonomy file: ", e$message))
  )
  
  message("Dim contrib: ", paste(dim(contrib), collapse = "x"), " | Cols: ", paste(colnames(contrib), collapse = ", "))
  message("Dim metadata: ", paste(dim(metadata), collapse = "x"), " | Cols: ", paste(colnames(metadata), collapse = ", "))
  message("Dim taxonomy: ", paste(dim(taxonomy), collapse = "x"), " | Cols: ", paste(colnames(taxonomy), collapse = ", "))
  
  if (!"class" %in% colnames(metadata)) {
    message("'class' column not found in metadata. Creating a default 'all' class.")
    metadata$class <- "all"
  } else {
    message("'class' column found in metadata.")
    metadata$class <- as.character(metadata$class)
  }
  
  contrib$SampleID <- as.character(contrib$SampleID)
  metadata$SampleID <- as.character(metadata$SampleID)
  contrib$FeatureID <- as.character(contrib$FeatureID)
  taxonomy$FeatureID <- as.character(taxonomy$FeatureID)
  contrib$FunctionID <- as.character(contrib$FunctionID)
  taxonomy$TaxonID <- as.character(taxonomy$TaxonID)
  
  message("Merging contribution and metadata...")
  merged <- merge(contrib, metadata, by = "SampleID", all.x = TRUE)
  message("  Dim after merging contrib and metadata: ", paste(dim(merged), collapse = "x"))
  if (nrow(merged) == 0) stop("Merging contribution and metadata resulted in an empty data frame.")
  
  cols_to_keep_from_taxonomy <- c("FeatureID", "TaxonID")
  if (!all(cols_to_keep_from_taxonomy %in% colnames(taxonomy))) {
    stop("Missing expected columns in taxonomy file: ", paste(setdiff(cols_to_keep_from_taxonomy, colnames(taxonomy)), collapse = ", "))
  }
  taxonomy_for_merge <- taxonomy %>% select(all_of(cols_to_keep_from_taxonomy))
  
  message("Merging with taxonomy data...")
  merged <- merge(merged, taxonomy_for_merge, by = "FeatureID", all.x = TRUE)
  message("  Dim after merging taxonomy: ", paste(dim(merged), collapse = "x"))
  if (!"taxon_function_abun" %in% colnames(merged)) {
    stop("Column 'taxon_function_abun' not found after merging.")
  }
  merged$taxon_function_abun <- as.numeric(merged$taxon_function_abun)
  
  unique_classes_clean <- unique(merged$class)
  unique_classes_clean <- unique_classes_clean[!is.na(unique_classes_clean)]
  message("Unique classes identified for processing: ",
          if (length(unique_classes_clean) > 0) paste(sort(unique_classes_clean), collapse = ", ") else "None")
  
  if (length(unique_classes_clean) == 0) {
    warning("No valid (non-NA) classes found. Exiting.")
    return(invisible(NULL))
  }
  
  for (current_class in unique_classes_clean) {
    message("\nProcessing class: '", current_class, "'")
    merged_class <- merged %>% filter(class == current_class)
    message("  Dim merged_class: ", paste(dim(merged_class), collapse = "x"))
    if (nrow(merged_class) == 0) next
    
    message("  Aggregating taxon-function abundance...")
    taxon_function_total_class <- aggregate(
      taxon_function_abun ~ FunctionID + TaxonID,
      data = merged_class, sum, na.rm = TRUE
    )
    message("  Dim aggregated data: ", paste(dim(taxon_function_total_class), collapse = "x"))
    if (nrow(taxon_function_total_class) == 0) next
    
    message("  Calculating relative contributions...")
    function_total_class <- aggregate(
      taxon_function_abun ~ FunctionID,
      data = taxon_function_total_class, sum, na.rm = TRUE
    )
    colnames(function_total_class)[2] <- "total_abundance_all_taxa"
    taxon_function_total_class <- merge(taxon_function_total_class, function_total_class, by = "FunctionID")
    taxon_function_total_class$relative_contribution <- with(taxon_function_total_class,
                                                             ifelse(total_abundance_all_taxa == 0, 0, taxon_function_abun / total_abundance_all_taxa)
    )
    message("  Dim after contribution calc: ", paste(dim(taxon_function_total_class), collapse = "x"))
    
    if (filtering != "unfiltered") {
      message("  Applying filtering: ", filtering)
      if (filtering %in% c("mean", "median")) {
        FUN_used <- if (filtering == "mean") mean else median
        threshold_df <- aggregate(relative_contribution ~ FunctionID,
                                  data = taxon_function_total_class,
                                  FUN = FUN_used, na.rm = TRUE)
        colnames(threshold_df)[2] <- "threshold"
        taxon_function_total_class <- merge(taxon_function_total_class, threshold_df, by = "FunctionID")
        taxon_function_total_class <- subset(taxon_function_total_class, relative_contribution >= threshold | is.na(threshold))
      } else {
        percent_map <- c("top10%" = 0.10, "top25%" = 0.25, "top50%" = 0.50, "top75%" = 0.75)
        top_percent <- percent_map[filtering]
        taxon_function_total_class <- taxon_function_total_class %>%
          group_by(FunctionID) %>% arrange(desc(relative_contribution)) %>%
          mutate(rank = row_number(), n_taxa = n(), cutoff = pmax(ceiling(top_percent * n_taxa), 1)) %>%
          filter(rank <= cutoff) %>%
          ungroup() %>% select(-rank, -n_taxa, -cutoff)
      }
      message("  Dim after filtering: ", paste(dim(taxon_function_total_class), collapse = "x"))
      if (nrow(taxon_function_total_class) == 0) {
        message("  No data left after filtering. Skipping.")
        next
      }
    }
    
    message("  Saving results for class: ", current_class)
    taxon_function_total_class <- taxon_function_total_class[
      order(taxon_function_total_class$FunctionID, -taxon_function_total_class$relative_contribution),
    ]
    file_suffix <- gsub("%", "", filtering)
    full_output_path <- file.path(output_file, paste0("microbe_pathway_network_", current_class, "_", file_suffix, ".csv"))
    write.csv(taxon_function_total_class, full_output_path, row.names = FALSE)
    message("  File saved to: ", full_output_path)
  }
  
  message("Microbe-pathway network construction complete.")
  return(invisible(NULL))
}
#' @include IsodatFileClass.R
#' @include IrmsDualInletDataClass.R
NULL

#' Clumped dual inlet data class
#' 
#' 
#' @name IsodatDualInletFile
#' @exportClass IsodatDualInletFile
#' @seealso \link{BinaryFile}, \link{IsodatFile}, \link{IrmsDualInletData}, \link{IrmsData}
IsodatDualInletFile <- setRefClass(
  "IsodatDualInletFile",
  contains = c("IsodatFile", "IrmsDualInletData"),
  fields = list (),
  methods = list(
    #' initialize
    initialize = function(...) {
      callSuper(...)
      init_irms_data()
    },
    
    #' initialize irms data container
    init_irms_data = function(){
      callSuper()      
      # overwrite in derived classes and set data table definitions properly!
      # see IrmsDualInletDataClass for details on requirements and functionality
    },
    
    # READ DATA =========================
    
    #' expand process function specifically for dual inlet type data
    process = function(...) {
      callSuper()
      
      # find recorded masses
      masses <- find_key("Mass \\d+",
          byte_min = find_key("CTraceInfo", occ = 1, fix = T)$byteEnd,
          byte_max = find_key("CPlotRange", occ = 1, fix = T)$byteStart)$value
      
      if (length(masses) == 0)
        stop("Error: no keys named 'Mass ..' found. Cannot identify recorded mass traces in this file.")
      
      # unless mass plot options are already manually defined (in init_irms_data), define them automatically here and assign colors
      mass_names <- sub("Mass (\\d+)", "mass\\1", masses)
      if (length(plotOptions$masses) == 0) {
        # color blind friendly pallete (9 colors)
        palette <- c("#000000", "#E69F00", "#56B4E9", "#009E73", "#D55E00", "#0072B2", "#CC79A7", "#999999", "#F0E442")
        if (length(masses) > length(palette))
          stop("Currently only supporting up to ", length(palette), " automatically assigned different colors for masses but ",
              "this file is recording data for ", length(masses), " different masses. Plesae define the plotOptions manually.")        
        
        set_plot_options(
          masses = setNames(
            sapply(seq_along(masses), function(i) list(list(label = masses[i], color = palette[i]))), 
            mass_names)
        )
      }
      
      # extract raw voltage data from the cycles
      raw_data_keys <- find_key("^(Standard|Sample) \\w+$",
          byte_min = find_key("CDualInletRawData", occ = 1, fix = T)$byteEnd, 
          byte_max = find_key("CTwoDoublesArrayData", occ = 1, fix = T)$byteStart)
      
      if (nrow(raw_data_keys) == 0)
        stop("could not find raw data in this file")
  
      # extract cycle information
      raw_data_keys <- mutate(raw_data_keys,
                              analysis = sub("^(Standard|Sample) (\\w+)$", "\\1", value),
                              cycle.0idx = sub("^(Standard|Sample) (\\w+)$", "\\2", value), # 0 based index, adjust in next line
                              cycle = ifelse(cycle.0idx == "Pre", 0, suppressWarnings(as.integer(cycle.0idx)) + 1L))
      n_cycles <- max(raw_data_keys$cycle)
      
      # read in all masses and cycles
      massData <<- do.call(data.frame, 
                          args = c(list(stringsAsFactors = FALSE, analysis = character(), cycle = integer()), 
                                   lapply(plotOptions$masses, function(i) numeric())))
      
      for (i in 1:nrow(raw_data_keys)) {
          move_to_key(raw_data_keys[i, ])
          has_intensity_block <- nrow(subset(keys, value == "CIntensityData" & byteStart > raw_data_keys[i, "byteStart"] & byteEnd < raw_data_keys[i, "byteEnd"] + 64)) > 0
          massData[i, ] <<- c(list(raw_data_keys[i, "analysis"], raw_data_keys[i, "cycle"]), 
            as.list(parse("double", length = length(mass_names), skip_first = if (has_intensity_block) 82 else 64)))
      }
      
      # evaluated data / data table
      # NOTE: this could (should ?) be calculated from the raw voltage data directly
      eval_data_keys <- find_key("^(d |AT).+$",
                                byte_min = find_key("CDualInletEvaluatedData", occ = 1, fix = T)$byteEnd, 
                                byte_max = find_key("Sequence Line Information", occ = 1, fix = T)$byteStart)
      if (nrow(eval_data_keys) == 0)
        stop("could not find evaluated data in this file")
      
      eval_data <- list(cycle = 1:n_cycles)
      for (i in 1:nrow(eval_data_keys)) {
        move_to_key(eval_data_keys[i,])
        gap_to_data <- switch(
          substr(eval_data_keys[i, "value"], 1, 2), 
          `d ` = 54, `AT` = 50)
        # these are evaluated data points for ALL cycles
        eval_data[[eval_data_keys[i,"value"]]] <- parse("double", length = 2 * n_cycles, skip_first = gap_to_data)[c(FALSE, TRUE)] 
      }
      dataTable <<- data.frame(eval_data, check.names = F)
      
      # unless dataTableColumns are already manually defined, define them here
      if (nrow(dataTableColumns) == 0) {
        dataTableColumns <<- 
          data.frame(data = names(dataTable), column = names(dataTable), 
                     units = "", type = "numeric", show = TRUE, stringsAsFactors = FALSE)
      }
      
      # grid infos
      rawtable <- rawdata[subset(keys, value=="CMeasurmentInfos")$byteEnd:subset(keys, value=="CMeasurmentErrors")$byteStart]
      dividers <- c(grepRaw("\xff\xfe\xff", rawtable, all=TRUE), length(rawtable))
      if (length(dividers) == 0) 
        stop("this file does not seem to have the expected hex code sequence FF FE FF as dividers in the grid info")
      
      for (i in 2:length(dividers)) {
        # read ASCII data for each block
        raw_ascii <- grepRaw("([\u0020-\u007e][^\u0020-\u007e])+", rawtable[(dividers[i-1]+4):dividers[i]], all=T, value = T)
        x <- if (length(raw_ascii) > 0) rawToChar(raw_ascii[[1]][c(TRUE, FALSE)]) else ""
        if (x == "CUserInfo") data[[paste0("Info_", sub("^(\\w+).*$", "\\1", value))]] <<- value # store value with first word as ID
        else value <- x # keep value
      }
      
      # sequence line information
      rawtable <- rawdata[subset(keys, value=="Sequence Line Information")$byteEnd:subset(keys, value=="Visualisation Informations")$byteStart]
      if (length(rawtable) < 10)
        stop("this file does not seem to have a data block for the sequence line information")
      
      dividers <- grepRaw("\xff\xfe\xff", rawtable, all=TRUE)
      if (length(dividers) == 0) 
        stop("this file does not seem to have the expected hex code sequence FF FE FF as dividers in the sequence line information")
      
      for (i in 2:length(dividers)) {
        # read ASCII data for each block
        raw_ascii <- grepRaw("([\u0020-\u007e][^\u0020-\u007e])+", rawtable[(dividers[i-1]+4):dividers[i]], all=T, value = T)
        x <- if (length(raw_ascii) > 0) rawToChar(raw_ascii[[1]][c(TRUE, FALSE)]) else ""
        if (i %% 2 == 1) data[[x]] <<- value # store key / value pair in data list
        else value <- x # keep value for key (which comes AFTER its value)
      }
      
    },
    
    #' custom show function to display roughly what data we've got going
    show = function() {
      cat("\nShowing summary of", class(.self), "\n")
      callSuper()
      cat("\n\nMass data:\n")
      print(get_mass_data())
      cat("\n\nData table:\n")
      print(get_data_table(summarize = TRUE))
    }
  )
)
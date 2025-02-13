# PIVOT: Platform for Interactive analysis and Visualization Of Transcriptomics data
# Copyright (c) 2015-2018, Qin Zhu and Junhyong Kim, University of Pennsylvania.
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.



############################# Folder and data file selection handler ###########################

shinyFiles::shinyDirChoose(input, 'data_folder', session=session, roots=c(home='~'))

output$data_folder_show <- renderPrint(
    if(is.null(input$data_folder)) {
        "No folder is selected"
    }
    else {
        shinyFiles::parseDirPath(roots=c(home='~'), input$data_folder)
    }
)


output$select_data <- renderUI({
    if(is.null(input$data_folder)) return()
    datadir <- shinyFiles::parseDirPath(roots=c(home='~'), input$data_folder)
    input$file_search # Respond to this
    isolate({
        dataFiles <- list.files(datadir, full.names = T)
        dataFiles_names <- list.files(datadir, full.names = F)

        filelis_all <- as.list(dataFiles)
        filelis_all <- setNames(filelis_all, dataFiles_names)

        filelis <- grep(input$file_search, filelis_all, value = "TRUE")

        if(length(filelis) <= 25) {
            inlen <- length(filelis)
        } else {
            inlen <- 25
        }

        selectInput("dataFiles",
                    label = NULL,
                    choices = filelis,
                    selected = filelis,
                    multiple = T,
                    selectize = F,
                    size = inlen
        )
    })

})



observeEvent(input$submit_dir, {
    #print(input$dataFiles)
    if(is.null(input$dataFiles))
    {
        session$sendCustomMessage(type = "showalert", "Please specify your data input.")
        return()
    }

    if(length(input$dataFiles) < 2) {
        session$sendCustomMessage(type = "showalert", "Too few samples or the input format is incorrect!")
        return()
    }

    if(!is.null(r_data$glb.raw)) # This is not first time submission, then clean up previous session
    {
        r_data <- init_state(r_data)
        r_data <- clear_design(r_data)
    }

    withProgress(message = 'Processing', value = 0, {
        dfList <- list()
        r_data$file_info$type <- "dir"
        r_data$file_info$path <- input$data_folder$path

        n <- length(input$dataFiles)
        for(f in input$dataFiles) {
            dat <- read.table(f, header=T)
            sampleName <- sub("Sample_", "", sub("[.].*", "", basename(f)), ignore.case = T)
            names(dat) <- c("feature", sampleName)
            dfList[[length(dfList) + 1]] <- dat
            incProgress(0.5/n, detail = paste(sampleName, "added"))
        }

        incProgress(0.1, detail = "Bringing together samples...")
        allCountsRaw <- plyr::join_all(dfList, "feature")
        # Make sure the dataframe do not contain NAs
        if(sum(is.na(allCountsRaw))) {
            session$sendCustomMessage(type = "showalert", "NA value was produced... Maybe the samples are not from the same species? Please check again!")
            return()
        }

        rownames(allCountsRaw) <- allCountsRaw$feature
        colnames(allCountsRaw) <- make.names(colnames(allCountsRaw), unique=T) # Make sure the sample names are converted to the format accepted by R
        allCountsRaw <- allCountsRaw %>% dplyr::select(-feature)

        r_data$glb.raw <- allCountsRaw # global raw
        # Make sure the names are good
        tmp_sample_name <- colnames(r_data$glb.raw)
        colnames(r_data$glb.raw) <- tmp_sample_name
        tmp_feature_name <- make.names(rownames(r_data$glb.raw), unique = TRUE)
        rownames(r_data$glb.raw) <- tmp_feature_name

        ### Feature exclusion
        # Exclude low count genes
        if(input$input_threshold_type == "mean")
            r_data$glb.raw <- r_data$glb.raw[rowMeans(r_data$glb.raw) > input$min_cnt_avg, ] # The default filter is 0.
        else if(input$input_threshold_type == "sum")
            r_data$glb.raw <- r_data$glb.raw[rowSums(r_data$glb.raw) > input$min_cnt_sum, ]
        else {
            session$sendCustomMessage(type = "showalert", "Unknown threshold type.")
            r_data <- init_state(r_data)
            r_data <- clear_design(r_data)
            return()
        }
        # Extract and exclude ERCC
        r_data$ercc <- r_data$glb.raw[grep("ERCC(-|[.])\\d{5}", rownames(r_data$glb.raw)),]
        if(grepl("ERCC", input$proc_method) && nrow(r_data$ercc) == 0) {
            session$sendCustomMessage(type = "showalert", "No ERCC detected.")
            r_data <- init_state(r_data)
            r_data <- clear_design(r_data)
            return()
        }
        if(input$exclude_ercc && nrow(r_data$ercc) > 0) {
            r_data$glb.raw<-r_data$glb.raw[-which(rownames(r_data$glb.raw) %in% rownames(r_data$ercc)), ]
        }
        #assign("raw", r_data$glb.raw , env=.GlobalEnv)

        r_data$sample_name <- colnames(r_data$glb.raw) # Get the sample_key
        r_data$feature_list <- rownames(r_data$glb.raw) # Get the feature_key

        incProgress(0.1, detail = "Perform data normalization...")

        error_I <- 0
        error_msg <- NULL

        tryCatch({
            result<-normalize_data(method = input$proc_method,
                                   params = list(
                                       gene_length = r_data$gene_len,
                                       control_gene = r_data$control_gene,
                                       ruvg_k = input$ruvg_k,
                                       ruvg_round = input$ruvg_round,
                                       deseq_threshold = input$deseq_threshold/100,
                                       expected_capture_rate = input$expected_capture_rate,
                                       ercc_added = input$norm_ercc_added,
                                       ercc_dilution = input$norm_ercc_ratio,
                                       ercc_mix_type = input$norm_ercc_mix_type,
                                       ercc_detection_threshold = input$ercc_detection_threshold,
                                       ercc_std = erccStds
                                   ),
                                   raw = r_data$glb.raw, ercc = r_data$ercc)
        }, error = function(e){
            error_I <<- 1
            error_msg <<- e
        })

        if(error_I) {
            r_data <- init_state(r_data)
            r_data <- clear_design(r_data)
            session$sendCustomMessage(type = "showalert", paste0("Error detected: ", error_msg, "Please recheck format/try different normalization procedure."))
            return()
        }

        r_data$norm_param <- result$norm_param
        r_data$raw <- r_data$glb.raw
        r_data$df <- result$df
        incProgress(0.2, detail = "Adding metadata...")
        r_data$glb.meta <- data.frame(sample = r_data$sample_name)
        r_data <- init_meta(r_data)
        r_data <- update_history(r_data, NA, "Input", "Input counts directory", list(feature = r_data$feature_list, sample = r_data$sample_name, df = r_data$df), r_data$norm_param$method, r_data$norm_param)

        setProgress(1)
    })
})


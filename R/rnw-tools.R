#' @title Sweave to RMarkdown
#' @description automated function for converting a single Sweave file to R Markdown file
#' @param input_file input Sweave file path
#' @param front_matter_type knit output type for the RMarkdown file, default is "vignettes"
#' @param clean_up whether to clean up the intermediate files, default is TRUE
#' @param autonumber_eq whether to autonumber the equations, default is FALSE
#' @note Use pandoc version greater than or equal to 3.1
#'
#' @return True if R Markdown file successfully generated in the same folder
#'
#' @export
#' @examples
#' # move example Sweave article and associated files to a temporary directory
#' example_dir <- system.file("examples", "sweave_article", package = "texor")
#' file.copy(from = example_dir, to = tempdir(), recursive = TRUE)
#' article_dir <- file.path(tempdir(), "sweave_article")
#'
#' # convert example Sweave article to Rmd
#' rnw_to_rmd(file.path(article_dir, "example.Rnw"),
#'            front_matter_type = "vignettes",
#'            clean_up = TRUE,
#'            autonumber_eq = TRUE)
#'
#' # convert Rmd to HTML (comment this step to avoid failure on R CMD Check)
#' # rmarkdown::render(file.path(article_dir, "example.Rmd"))
#' # browseURL(file.path(article_dir, "example.html"))
#'
#' # remove temporary files
#' unlink(article_dir, recursive = TRUE)
rnw_to_rmd <- function(input_file, front_matter_type = "vignettes", clean_up = TRUE, autonumber_eq = FALSE) {
    if (!pandoc_version_check()) {
        warning(paste0("pandoc version too old, current-v : ",rmarkdown::pandoc_version()," required-v : >=3.1"))
        return(FALSE)
    }
    dir <- dirname(input_file)
    input_file_name <- basename(input_file)
    if(!dir.exists(dir)) {
        stop("Directory does not exist")
    }
    dir <- xfun::normalize_path(dir)
    date <- Sys.Date()

    # Stage 01: pre process beofre using part of texor::latex_to_web()
    # Step 01: Convert Rnw to knitr and tex
    knitr::Sweave2knitr(input_file)
    input_file <- gsub("[.]([^.]+)$", "-knitr.\\1", input_file)
    output_file <- gsub(".Rnw", ".tex", input_file)
    if(!file.exists(input_file)) {
        stop("knitr file not created")
    }
    patch_rnw_abstract(input_file)

    # PHINNEY: donnot compile the knitr file to save time
    # knitr::knit(input = input_file, output = output_file) # it will print as warning/highlight
    # if(!file.exists(output_file)) {
    #     stop("tex file not created")
    # }
    # Step 02: Separate knitr file to code chunks and tex
    part_file_path <- rnw_remove_code_chunk(input_file)
    md_code_file_path <- part_file_path$md_file_path
    rnw_file_path <- part_file_path$rnw_file_path

    # Step 03: only keep the body of tex file (\document)
    rnw_read_body(rnw_file_path)

    # Step 04: renme original .tex file to .tex.bak
    # PHINNEY: donnot compile the knitr file to save time
    # file.rename(output_file, paste0(output_file, ".bak"))

    # Stage 02: Convert tex to Markdown (part of texor::latex_to_web())
    # TODO: We just use texor::latex_to_web(dir, log_steps = TRUE, temp_mode = FALSE,
    #                                       auto_wrapper = TRUE, interactive_mode = FALSE) for now
    interactive_mode = FALSE
    auto_wrapper = TRUE
    web_dir = FALSE
    compile_rmd_in_temp = !interactive_mode
    # Step 01: Include Meta-fix style file
    wrapper <- get_wrapper_type(dir,
                                auto_wrapper = auto_wrapper,
                                interactive_mode = interactive_mode) #wrapper file name
    file_name <- get_texfile_name(dir)
    include_style_file(dir)
    wrapper <- get_wrapper_type(dir, auto_wrapper = auto_wrapper)

    # PHINNEY: patch for self-defined macros
    wrapper_auto_sty(input_file)


    rebib::aggregate_bibliography(dir)

    patch_code_env(dir)
    patch_table_env(dir)
    data <- handle_figures(dir, file_name)
    patch_equations(dir)
    # Step - 6 : patch figure environments to figure
    patch_figure_env(dir)
    # Step - 7 : find package references
    meta <- pre_conversion_statistics(dir)

    # Step - 8 : Add reference caption
    if (rebib::citation_reader(rnw_file_path)$count > 0) {
        add_reference_caption(rnw_file_path)
    }

    remove_unsupport_commands(rnw_file_path)

    # Step - 9 : Convert to markdown
    convert_to_markdown(dir, autonumber_eq = autonumber_eq)


    # Stage 03: Post process after convert to markdown

    # Step 01: patch for R code
    md_file_path <- paste0(dir, "/RJwrapper.md")
    rnw_patch_inline_code(md_file_path)
    rnw_patch_code_chunk(md_file_path, md_code_file_path)

    # Step 02: patch for vignette entry
    if(front_matter_type == "vignettes") {
        rnw_patch_vignette_entry(md_file_path, input_file)
    }


    # Stage 04
    # Step - 9 : generate R markdown file with
    #             metadata from DESCRIPTION, tex file
    #             and file path
    # Note : the below function will work on any article, However ideally it needs a
    # folder structure similar to RJournal style /YYYY-ZZ/YYYY-MMM where
    # YYYY is the year, ZZ is the Journal issue number and MMM is the DOI
    # referral(unique article number).

    rnw_generate_rmd(dir,web_dir = web_dir, interactive_mode = interactive_mode, front_matter_type = front_matter_type)
    # post_data <- yaml::read_yaml(paste0(dir,"/post-conversion-meta.yaml"))

    # Step - 10 : rename the file to the original file name
    file.rename(paste0(dir,"/RJwrapper.Rmd"), paste0(dir,"/",gsub(".Rnw", ".Rmd", input_file_name)))

    # Step - 11 : clean up the intermediate files
    if(clean_up) {
        clean_up_files(dir)
    }

    return(TRUE)
}

rnw_remove_code_chunk <- function(input_file) {
    dir <- dirname(input_file)
    if(!dir.exists(dir)) {
        stop("Directory does not exist")
    }
    dir <- xfun::normalize_path(dir)

    md_file_path <- paste(toString(tools::file_path_sans_ext(input_file)),
                     "-part1.md", sep = "")
    input_file_path <- paste(dir, basename(input_file), sep = "/")
    md_file_path <- xfun::normalize_path(md_file_path)
    rnw_file_path <- gsub("-knitr.Rnw", "-generated.tex", input_file)

    sweave_code_reader <- system.file(
        "sweave_code_reader.lua", package = "texor")
    sweave_code_remove <- system.file(
        "sweave_code_remove.lua", package = "texor")
    r_code_chunk_patcher <- system.file(
        "r_code_chunk_patcher.lua", package = "texor")
    pandoc_opt_code_chunk <- c("--resource-path", dir,
                    "-f", sweave_code_reader,
                    "--lua-filter", r_code_chunk_patcher)
    pandoc_opt_other <- c("--resource-path", dir,
                    "-f", sweave_code_remove)
    markdown_output_format <- "markdown-simple_tables-pipe_tables-fenced_code_attributes"

    rmarkdown::pandoc_convert(input_file_path,
                              from = "latex",
                              to = markdown_output_format,
                              options = pandoc_opt_code_chunk,
                              output = md_file_path,
                              verbose = TRUE)
    rmarkdown::pandoc_convert(input_file_path,
                              from = "latex",
                              to = "latex",
                              options = pandoc_opt_other,
                              output = rnw_file_path,
                              verbose = TRUE)

    if (!file.exists(md_file_path)) {
        stop("Markdown part file not created")
    }
    if (!file.exists(rnw_file_path)) {
        stop("Rnw part file not created")
    }

    return(list(md_file_path = md_file_path, rnw_file_path = rnw_file_path))
}

rnw_read_body <- function(input_file) {
    if(!file.exists(input_file)) {
        stop("File does not exist")
    }

    file_content <- readLines(input_file)
    # delete \begin{document}, \end{document}, \usepackage{...}, \documentclass{...}
    file_content <- file_content[!grepl("\\\\usepackage(\\[.*\\])?\\{.*\\}", file_content)]
    file_content <- file_content[!grepl("\\\\documentclass(\\[.*\\])?\\{.*\\}", file_content)]
    file_content <- file_content[!grepl("\\\\begin\\{document\\}", file_content)]
    file_content <- file_content[!grepl("\\\\end\\{document\\}", file_content)]
    xfun::write_utf8(file_content, input_file)
    return(TRUE)

    latex_body_reader <- system.file(
        "latex_body_reader.lua", package = "texor")

    pandoc_opt <- c("--resource-path", dirname(input_file),
                               "-f", latex_body_reader)

    rmarkdown::pandoc_convert(input_file,
                              from = "latex",
                              to = "latex",
                              options = pandoc_opt,
                              output = input_file,
                              verbose = TRUE)
    return(TRUE)
}

rnw_patch_inline_code <- function(input_file_path) {
    if(!file.exists(input_file_path)) {
        stop("File does not exist")
    }
    file_content <- readLines(input_file_path)
    file_content <- gsub("\\\\Sexpr\\{(.*?)\\}", "`r \\1`", file_content)
    file_content <- gsub("\\\\verb\\|r (.*?)\\|", "`r \\1`", file_content)
    xfun::write_utf8(file_content, input_file_path)
    return(TRUE)
}

rnw_patch_code_chunk <- function(input_file_path, code_file_path) {
    if(!file.exists(input_file_path) || !file.exists(code_file_path)) {
        stop("File does not exist")
    }
    code_chunk_content <- readLines(code_file_path)
    chunks <- list()
    current_chunk <- NULL
    in_chunk <- FALSE
    for (line in code_chunk_content) {
        if (grepl("^```\\s*\\{r", line)) {
            # Start of a new chunk
            if (!is.null(current_chunk)) {
                # Save the previous chunk
                chunks <- c(chunks, list(current_chunk))
            }
            current_chunk <- line
            in_chunk <- TRUE
        } else if (grepl("^```$", line) && in_chunk) {
            # End of the current chunk
            current_chunk <- c(current_chunk, line)
            chunks <- c(chunks, list(current_chunk))
            current_chunk <- NULL
            in_chunk <- FALSE
        } else if (in_chunk) {
            # Inside a chunk
            current_chunk <- c(current_chunk, line)
        }
    }
    if (!is.null(current_chunk)) {
        # Save the last chunk
        chunks <- c(chunks, list(current_chunk))
    }

    chunk_index <- 1
    file_content <- readLines(input_file_path)
    modified_content <- lapply(file_content, function(line) {
        if (grepl("<!--R_CODE_CHUNK_PLACEHOLDER-->", line)) {
            if (chunk_index <= length(chunks)) {
                replacement <- paste(chunks[[chunk_index]], collapse = "\n")
                chunk_index <<- chunk_index + 1
                return(replacement)
            } else {
                return(line)
            }
        } else {
            return(line)
        }
    })

    modified_content <- unlist(modified_content, use.names = FALSE)
    xfun::write_utf8(modified_content, input_file_path)
    return(TRUE)
}

rnw_patch_vignette_entry <- function(md_file_path, rnw_file_path) {
    if(!file.exists(md_file_path) || !file.exists(rnw_file_path)) {
        stop("File does not exist")
    }
    md_content <- readLines(md_file_path)
    rnw_content <- readLines(rnw_file_path)

    # Extract the entry name from the Rnw file
    entry_name <- NULL
    depend_name <- NULL
    for (line in rnw_content) {
        if (grepl("%+\\s*\\\\VignetteIndexEntry", line)) {
            entry_name <- gsub("%+\\s*\\\\VignetteIndexEntry\\{(.*)\\}", "\\1", line)
            break
        }
    }
    for (line in rnw_content) {
        if (grepl("%+\\s*\\\\VignetteDepends", line)) {
            depend_name <- gsub("%+\\s*\\\\VignetteDepends\\{(.*)\\}", "\\1", line)
            break
        }
    }

    if (is.null(entry_name)) {
        entry_name <- basename(rnw_file_path)
        # stop("Vignette entry name not found")
    }

    # Add the entry name to the front yaml in md file
    entry_added <- FALSE
    modified_content <- vector("list", length(md_content))
    for (i in seq_along(md_content)) {
        line <- md_content[[i]]
        if (!entry_added && grepl("^---$", line)) {
            modified_content[[i]] <- c(line, paste0("VignetteIndexEntry: ", entry_name))
            if (!is.null(depend_name)) {
                modified_content[[i]] <- c(modified_content[[i]], paste0("VignetteDepends: ", depend_name))
            } else{
                modified_content[[i]] <- c(modified_content[[i]], paste0("VignetteDepends: ", ""))
            }
            entry_added <- TRUE
        } else {
            modified_content[[i]] <- line
        }
    }

    modified_content <- unlist(modified_content, use.names = FALSE)
    xfun::write_utf8(modified_content, md_file_path)
    return(TRUE)
}

patch_rnw_abstract <- function(rnw_file_path) {
    if(!file.exists(rnw_file_path)) {
        stop("File does not exist")
    }
    rnw_content <- readLines(rnw_file_path)
    in_abstract <- FALSE
    abstract_start <- NULL
    abstract_end <- NULL
    modified_content <- list()

    for (i in seq_along(rnw_content)) {
        line <- rnw_content[i]
        # check in_abstract above to prevent modify the same line
        if (grepl("\\\\abstract\\{", line, ignore.case = TRUE)) {
            in_abstract <- TRUE
            abstract_start <- i
            line <- sub("(?i)\\\\abstract\\{", "\\\\begin{abstract}", line, perl = TRUE)
        }
        if (in_abstract && grepl("(?<!\\\\begin\\{abstract)\\}$", line, perl = TRUE)) {
            in_abstract <- FALSE
            abstract_end <- i
            line <- sub("\\}$", "\\\\end{abstract}", line)
        }
        modified_content[i] <- line
    }

    modified_content <- unlist(modified_content, use.names = FALSE)
    xfun::write_utf8(modified_content, rnw_file_path)
    return(TRUE)
}

wrapper_auto_sty <- function(rnw_file_path, wrapper_name = "RJwrapper.tex") {
    if (!file.exists(rnw_file_path)) {
        stop("File does not exist")
    }
    article_dir <- xfun::normalize_path(dirname(rnw_file_path))
    article_files <- list.files(article_dir, recursive = FALSE)
    sty_files <- article_files[grep(pattern = "[.]sty$", article_files)]
    sty_files <- sty_files[!grepl(pattern = "Metafix[.]sty$", sty_files)]
    rnw_content <- readLines(rnw_file_path)
    include_sty_files <- list()
    for (i in seq_along(rnw_content)) {
        line <- rnw_content[[i]]
        if (grepl("\\\\usepackage\\{", line)) {
            sty_file <- gsub(".*\\{(.*)\\}", "\\1", line)
            if (paste0(sty_file, ".sty") %in% sty_files) {
                include_sty_files <- c(include_sty_files, sty_file)
            }
        }
    }
    wrapper_path <- file.path(article_dir, wrapper_name)
    if (!file.exists(wrapper_path)) {
        stop("Wrapper file does not exist")
    }
    wrapper_content <- readLines(wrapper_path)
    modified_content <- list()
    # avoid duplicate sty files
    for (i in seq_along(wrapper_content)) {
        line <- wrapper_content[[i]]
        if (grepl("\\\\usepackage\\{", line)) {
            sty_file <- gsub(".*\\{(.*)\\}", "\\1", line)
            if (sty_file %in% include_sty_files) {
                include_sty_files <- include_sty_files[include_sty_files != sty_file]
            }
        }
    }
    # add sty file after \usepackage{Metafix}
    for (i in seq_along(wrapper_content)) {
        line <- wrapper_content[[i]]
        modified_content <- c(modified_content, line)
        if (grepl("\\\\usepackage\\{Metafix\\}", line)) {
            for (sty_file in include_sty_files) {
                modified_content <- c(modified_content, paste0("\\usepackage{", sty_file, "}"))
            }
        }
    }
    modified_content <- unlist(modified_content, use.names = FALSE)
    xfun::write_utf8(modified_content, wrapper_path)
    return(TRUE)
}

clean_up_files <- function(work_dir, intermediate_file_list = NULL) {
    if (is.null(intermediate_file_list)) {
        # get all file name in work_dir
        all_files <- list.files(work_dir, recursive = FALSE, full.names = TRUE)
        # remove all intermediate files in work_dir (.bk, .bak, .yaml, .txt, .md, .tex, -knitr.Rnw)
        intermediate_file_list <- c("\\.bk$", "\\.bak$", "\\.yaml$", "\\.txt$", "\\.md$", "\\.tex$",
                                    "-knitr\\.Rnw$", "Metafix\\.sty$")
        for (file in all_files) {
            # match end of file name
            pattern <- paste("(", intermediate_file_list, ")", collapse = "|", sep = "")
            if (grepl(paste0(".*", pattern, sep = ""), file)) {
                file.remove(file)
            }
        }
        return(TRUE)
    }
    all_files <- list.files(work_dir, recursive = FALSE, full.names = TRUE)
    for (file in all_files) {
        if (file %in% intermediate_file_list) {
            file.remove(file)
        }
    }
    return(TRUE)
}

add_reference_caption <- function(rnw_file_path) {
    if (!file.exists(rnw_file_path)) {
        stop("File does not exist")
    }
    rnw_content <- readLines(rnw_file_path)
    # replace \bibliography{...} with \section*{References}
    modified_content <- list()
    for (i in seq_along(rnw_content)) {
        line <- rnw_content[[i]]
        if (grepl("\\\\bibliography\\{", line, ignore.case = TRUE)) {
            modified_content <- c(modified_content, "\\section*{References}")
        }
        modified_content <- c(modified_content, line)
    }
    modified_content <- unlist(modified_content, use.names = FALSE)
    xfun::write_utf8(modified_content, rnw_file_path)
    return(TRUE)
}

remove_unsupport_commands <- function(rnw_file_path) {
    if (!file.exists(rnw_file_path)) {
        stop("File does not exist")
    }
    rnw_content <- readLines(rnw_file_path)
    modified_content <- list()
    for (i in seq_along(rnw_content)) {
        line <- rnw_content[[i]]
        # remove \vspace{...}, \hspace{...}, \vspace*{...}, \hspace*{...}
        if (grepl("^\\\\vspace\\{.*\\}$", line) ||
            grepl("^\\\\hspace\\{.*\\}$", line) ||
            grepl("^\\\\vspace\\*\\{.*\\}$", line) ||
            grepl("^\\\\hspace\\*\\{.*\\}$", line)) {
            next
        }
        modified_content <- c(modified_content, line)
    }
    modified_content <- unlist(modified_content, use.names = FALSE)
    xfun::write_utf8(modified_content, rnw_file_path)
    return(TRUE)
}

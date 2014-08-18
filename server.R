suppressMessages(require(shiny))
suppressMessages(require(GenomicRanges))
suppressMessages(require(RColorBrewer))
suppressMessages(require(rtracklayer))
suppressMessages(require(doMC)); registerDoMC(5) #TODO make this a param in config file

source("process_samps.R")
source("plotters.R")

# defaults
verbose <- T #### set to T for debugging
if (verbose) cat("************\nDebug mode\n*****************\n")
# increase max file size for reference chromosomes to 10MB
options(shiny.maxRequestSize=10*1024^2)
options(scipen=10)

configSet <- listConfig() # load config for all datasets 

# Define server logic required to plot variables
shinyServer(
function(input, output, session){
		cat("In shinyServer\n")
		updateCollapse(session, id = "main_collapse",  open = "col_plot", close = NULL)

	# which button was last pressed?updateCollapse(session, id = "collapse1", multiple = FALSE, open = NULL, close = NULL)
	# this is needed to separate data load from plot plot.
	values <- reactiveValues()
	values$lastAction <- NULL
	observe({if (input$getData!=0) { values$lastAction <- "data"}})
	observe({if (input$loadPlot!=0) {values$lastAction <- "plot"}})

	# tier 0 : shows up when page is loaded.
	output$pickData <- renderUI({selectInput("dataset", "", names(configSet), width="750px")	})
	# tier 1 : happens when 'make active dataset' button is clicked.
    refreshConfig <- reactive({
   		if (input$getData == 0) return(NULL) # only depends on first button
		updateCollapse(session, id="main_collapse", open="col_settings", close="col_activate")
		if (verbose) cat("* Refreshing config")
		settings <- configSet[[input$dataset]]
		allDat <- settings$allDat
		chromsize <- settings$chromsize
		groupKey <- settings$groupKey
		configParams <- settings$configParams
		isolate({return(settings)})
   })


  output$o_groupBy <- renderUI({ 
  if (input$getData == 0) return(NULL)
  	settings <- isolate({refreshConfig()}); if (is.null(settings)) return(NULL) 
	groupNames <- settings$configParams$groupCols
	selectInput("groupBy", "Group samples by:", c(groupNames,"(none)"),
		selected=settings$configParams$defaultGroup)
})
  if (verbose) cat("\tGot by groupBy\n")

  output$dataname <- renderUI({
   if (input$getData == 0) return(NULL)
  	settings <- isolate({refreshConfig()}); if (is.null(settings)) return(NULL) 
	fluidRow(
	column(9,
	HTML(paste(
		'<span style="color:#ffffff;font-size:20px">Active dataset:',
		sprintf('<span style="color:#ffd357; font-weight:600">%s</span>', settings$configParams[["name"]])),
		sprintf(': build <span style="color:#ffd357;font-weight:600">%s</span></span>', settings$configParams[["genomeName"]]),
		sep="")
	), column(3,HTML(sprintf('<em style="margin-top:10px">%i samples available</em>', nrow(settings$allDat))))
	)
	})

	output$o_sampleCount <- renderUI({
  	settings <- isolate({refreshConfig()}); if (is.null(settings)) return(NULL) 
	if (input$getData==0) return(NULL)
	if (is.null(input$o_sampleTable)) {
		x <- nrow(settings$allDat) 
	} else if (length(input$o_sampleTable)==1) {
		if (input$o_sampleTable==-1) {
		x <- 0 #nrow(settings$allDat) 
		}
	}  else {
		tmp <- matrix(input$o_sampleTable,byrow=T,ncol=ncol(settings$allDat)-1); 
		x <- nrow(tmp)
	}
	HTML(sprintf("<i>%i samples selected</i>\n", x))
	})
  if (verbose) cat("\tGot by sampleCount\n")
  
  ### region help text
  output$mychrom <- renderUI({
   if (input$getData == 0) return(NULL)
  	settings <- isolate({refreshConfig()}); if (is.null(settings)) return(NULL) 
    
   source(sprintf("data_types/%s.R", settings$configParams$datatype))
    myfiles <- settings$allDat; sq <- getSeqinfo(myfiles$bigDataURL[1])
    selectInput("chrom", "Sequence:", sq)
  })
  
  output$csize <- renderUI({ #chrom size message
   if (input$getData == 0) return(NULL)
  	settings <- isolate({refreshConfig()}); if (is.null(settings)) return(NULL) 
    if(!is.null(input$chrom)){
    thischromsize <- settings$chromsize[which(settings$chromsize$chrom == input$chrom),2]
    HTML(sprintf("<b>Chrom max: %s bp</b>", format(thischromsize,big.mark=",")))
    }
  })
  
  output$coordSize <- renderUI({ #region width message
    r1 <- input$myrange1; r2 <- input$myrange2
    HTML(sprintf("<b>Region Width: %6.1f kb, %3.1f Mb</b>", (r2-r1)/1e3,(r2-r1)/1e6))
  })
  
  #### choosing data:
  output$colPal <- renderUI({selectInput("oCol", "Group Colour Scheme:", rownames(brewer.pal.info),"Dark2")})  

  output$customYlim <- renderUI({
	myout <- refreshData(); 
	if (is.null(myout))  return(NULL) 
	else {
		outdat <- myout[["outdat"]]
		tmp <- na.omit(as.numeric(as.matrix(outdat[,-(1:3)]))); 
		values <- c(quantile(tmp,c(0.005,0.995)),min(tmp),max(tmp))
	}
	print(values)
	sliderInput("customYlim", "Custom y-range", value=values[1:2],min=values[3],max=values[4])
  })

  output$o_colorBy <- renderUI({
  if (input$getData == 0) return(NULL)
  settings <- isolate({refreshConfig()}); if (is.null(settings)) return(NULL) 
  if (is.null(input$groupBy)) g <- settings$configParams$defaultGroup else g <- input$groupBy
	groupNames <- settings$configParams$groupCols
	selectInput("colorBy", "Color by:", c(groupNames,"(none)"),selected=g)
  })
  
  output$out_baseline <- renderUI({
   if (input$getData == 0) return(NULL)
  	settings <- isolate({refreshConfig()}); if (is.null(settings)) return(NULL) 
	if (is.null(input$groupBy)) g <- settings$configParams$defaultGroup else g <- input$groupBy
	if (g=="(none)") selVal <- NA else selVal <- settings$groupKey[[g]]
  	selectInput("whichBaseline","Baseline by", selVal)
  })
  
  
  #### for smoothing:
  output$bw2 <- renderUI({
      if(!is.na(input$myrange1) & !is.na(input$myrange2)){
        r1 <- input$myrange1
        r2 <- input$myrange2
        default.param <- (diff(c(r1,r2)))*0.02 # for default 5%
        numericInput("param2", "Smooth bw (bp):",
                     min=0, value=as.integer(default.param))
      }
  })
  
  output$bwMess2 <- renderUI({
    if(!is.na(input$myrange1) & !is.na(input$myrange2) & !is.null(input$param2)){
    rangeSize <- (input$myrange2-input$myrange1)
    bwSize <- input$param2
    bwProp <- (bwSize/rangeSize)*100
	binSize <- rangeSize/input$nbin1
    HTML(sprintf("<b>Bin size = %6.1f kb or %3.1f Mb<br>Bandwidth = %2.2f%% of win</b>", 
		binSize/1e3, binSize/1e6,bwProp))
    }
  })


  # sample table
  output$o_sampleTable <- renderDataTable({
  	if (input$getData==0) return(NULL)
  	settings <- isolate({refreshConfig()}); if (is.null(settings)) return(NULL)
	df <- settings$allDat; df <- df[,-which(colnames(df)=="bigDataURL")]
	return(df)
  }) #,options=list(bSortClasses=TRUE))

  # annotation view
  output$o_getAnnot <- renderUI({
  if (input$getData==0) return(NULL)
  	settings <- isolate({refreshConfig()}); if (is.null(settings)) return(NULL)
	anno <- read.delim(settings$configParams$annoConfig,sep="\t",header=T,as.is=T)
	checkboxGroupInput("anno", "The following annotation tracks are available for the current genome build:", choices=anno$name, selected=NULL)
  })

  ################################################################################################################################################################
	# tier 2: happens when 'Compute Plots' button is clicked.
	refreshData  <- reactive({
    if(input$loadPlot == 0) return(NULL)
    return(isolate({ # everything in this function waits for actionButton() to be selected before executing
		updateTabsetPanel(session, inputId="main_tabset", selected="Plot")
		if (verbose) cat("* In refreshData()\n")
		settings <- refreshConfig()
		cat("got out got out\n")

		# re-create data matrix from selectableDataTable input
		myfiles <- settings$allDat
	
		if (is.null(input$o_sampleTable)) {
			idx <- 1:nrow(myfiles)
		} else if (length(input$o_sampleTable)==1 && input$o_sampleTable==-1) {
			idx <- 1:nrow(myfiles)
		} else {
			tmp <- matrix(input$o_sampleTable,byrow=T,ncol=ncol(myfiles)-1); 
			colnames(tmp) <- colnames(myfiles)[-which(colnames(myfiles)=="bigDataURL")]
			prefilter_samps <- tmp[,"sampleName"]
			idx <- which(myfiles$sampleName %in% prefilter_samps)
		}
		if (!any(idx)) return("Please select at least 1+ sample using the Sample Selector");

		if(length(idx)==1) {tmp <- colnames(myfiles);  myfiles <- as.data.frame(myfiles[idx,]); colnames(myfiles) <- tmp;}
		else { myfiles <- myfiles[idx,]}
		cat(sprintf("After sample filtering, have %i samples\n", length(idx)))

        if(length(myfiles$sampleName) != unique(length(myfiles$sampleName))){ cat("There are repeat samples!\n"); browser()}

       cat("* Read files, bin data, create matrix\n") 
	   selRange <- GRanges(input$chrom, IRanges(input$myrange1,input$myrange2))
	   print(system.time(dat <- fetchData(myfiles, selRange,numBins=input$nbin1,
                                        datatype=settings$configParams$datatype,
                                        datatypeParams=settings$datatypeParams,
                                        verbose=verbose)))
	   bed <- dat$coords; alldat <- dat$values; rm(dat)

		baselineTxt <- ""
		cat("* Compute group statistics\n")
#		if (input$groupBy != "(none)") {
#        	mygroups <- settings$groupKey[[input$groupBy]]
#			mygroups <- intersect(mygroups, myfiles[,input$groupBy])
#			grp.summ <- computeAverages(myfiles,mygroups,bed,alldat,F,input$groupBy)
#				cat("\taverage computed\n")
#		
#			if (input$whichMetric != "normal") {
#				tmp <- baselineSamps(alldat, grp.summ, mygroups, 
#						input$whichMetric,input$whichBaseline, input$logMe)
#				alldat <- tmp$alldat; grp.summ <- tmp$grp.summ
#				logTxt <- "unlogged"; if (input$logMe) logTxt <- "log2"
#				baselineTxt <- sprintf("%s:%s (%s)", input$whichMetric, input$whichBaseline, logTxt)
#			}
#	        outdat <- cbind(bed, alldat, grp.summ); #rm(bed,alldat, grp.summ);
#		} else {
		outdat <- cbind(bed,alldat)
#		}

        myOut <- list(myfiles=myfiles, outdat=outdat,plotTxt=sprintf("%s: %s", settings$configParams$name, baselineTxt))
		### 1) myfiles: phenotype table
		### 2) outdat: data.frame with 3+N columns, where N is number of samples. First three columns are named chrom,start,end.
		### 3) plotTxt: character for plot title
		### 4) baselineTxt: title suffix indicating if samples have been baselined. -- OBSOLETE?
		cat("\tReturning output\n")
        return(myOut)
      })) # end of return(isolate()) 
  })

  output$scatplot <- renderPlot({ 
		  while (sink.number() > 0) sink(NULL)
cat("In renderPlot\n")
  if (is.null(values$lastAction)) return(NULL)
  if (values$lastAction=="data") return(NULL)
  if (input$loadPlot==0) return(NULL)

    myOut <- isolate({refreshData()});if(is.null(myOut)) return(NULL)
	cat("past refreshData\n")
  	settings <- isolate({refreshConfig()}) # don't change if dataset is selected by button is not pressed.
	cat("past refreshConfig")
      if(class(myOut) == "character") return(NULL) # print no graph
      else{
    	cat("* Render plot\n")
        myfiles <- myOut[["myfiles"]]
        outdat <- myOut[["outdat"]]
		settings$groupKey[["sampleName"]] <- myfiles$sampleName

		# update available groups based on selected samples.
		groupKey <- settings$groupKey
		for (k in names(groupKey)) {
			x <- groupKey[[k]]
			#TODO: define behaviour if no items match here
			groupKey[[k]] <- x[which(x %in% unique(myfiles[,k]))]
		}
		#TODO what if groupBy has no entries left?
		if (input$groupBy !="(none)" && is.null(groupKey[[input$groupBy]])){
			cat("you haven't decided what to do here, SP")
		}

		isolate({Smoother2 <- input$param2})
        
          mkScat(myfiles=myfiles, outdat = outdat,configParams=settings$configParams,
                 groupKey=groupKey, groupBy=input$groupBy, 
				 colorBy=input$colorBy, oCol=input$oCol, 				# color
				 plotViewType=input$plotType, plotType="smoo2", 		# plot type
				 compEB=computeEB, errb=F, param2=Smoother2, 			# errorbar related
                 whichYlim=input$whichYlim, customYlim=input$customYlim,	# ylim
				 legd=input$legd,											# legend 
				 plotTxt=myOut$plotTxt,selAnno=input$anno,
				 verbose=TRUE
          )
        }
	  #updateTabsetPanel(session,"main_tabset", "Plot")
  })

#  output$err1 <- renderUI({
#  HTML("")
#  cat("is err1 calling me?\n")
#    endDat <- refreshData()
#	# if character then it's an error message - needs to be printed
#    if(class(endDat)=="character") mess <- endDat
#    else if(is.null(endDat)) mess <- "<h4 id=errorMessage1 style='color:slategray'>Click <i>'Compute Plots'</i> to see default view<p>OR<p>Adjust settings and then hit <i>'Compute Plots'</i></h4>"
#    else {
#      endDat <- endDat[["outdat"]]
#      mess <- "All is right with the world."
#    }
#  HTML(mess)
 ## })

  #observe({
 #	print("click event")
#	print(input$o_sampleTable)
  #})

}) # end of shinyServer function

########################################################################################################


#' Nearest Neighbors Features
#'
#' Do \strong{feature engineering} on the original dataset and extract new features,
#' generating a new dataset. Since KNN is a nonlinear learner, it makes a 
#' nonlinear mapping from the original dataset, making possible to achieve 
#' a great classification performance using a simple linear model on the new 
#' features, like GLM or LDA.
#' 
#' This \strong{feature engineering} procedure generates \code{k * c} new 
#' features using the distances between each observation and its \code{k} 
#' nearest neighbors inside each class, where \code{c} is the number of class 
#' labels. The procedure can be summarized as follows:
#' \enumerate{
#'    \item Generate the first feature as the distances from the nearest 
#'    neighbor in the first class.
#'    \item Generate the second feature as the sum of distances from the 2 
#'    nearest neighbors inside the first class.
#'    \item Generate the third feature as the sum of distances from the 3 
#'    nearest neighbors inside the first class.    
#'    \item And so on.
#' }
#' Repeat it for each class to generate the \code{k * c} new features. For the 
#' new training set, a n-fold CV approach is used to avoid overfitting.
#' 
#' This procedure is not so simple. But this method provides a easy interface 
#' to do it, and is very fast.
#'
#' @param xtr matrix containing the training instances.
#' @param xte matrix containing the test instances.
#' @param ytr factor array with the training labels.
#' @param k number of neighbors considered (default is 1). This choice is 
#' directly related to the number of new features. So, be careful with it. A 
#' large \code{k} may increase a lot the computing time for big datasets.
#' @param normalize variable scaler as in \code{\link{fastknn}}.
#' @param folds number of folds (default is 5) or an array with fold ids between 
#' 1 and \code{n} identifying what fold each observation is in. The smallest 
#' value allowable is \code{nfolds=3}.
#' @param nthread the number of CPU threads to use (default is 1).
#'
#' @return \code{list} with the new data:
#' \itemize{
#'  \item \code{new.tr}: \code{matrix} with the new training instances.
#'  \item \code{new.te}: \code{matrix} with the new test instances.
#' }
#'
#' @author 
#' David Pinto.
#' 
#' @export
#' 
#' @examples
#' \dontrun{
#' library("mlbench")
#' library("caTools")
#' library("fastknn")
#' library("glmnet")
#' 
#' data("Ionosphere")
#' 
#' x <- data.matrix(subset(Ionosphere, select = -Class))
#' y <- Ionosphere$Class
#' 
#' # Remove near zero variance columns
#' x <- x[, -c(1,2)]
#' 
#' set.seed(2048)
#' tr.idx <- which(sample.split(Y = y, SplitRatio = 0.7))
#' x.tr <- x[tr.idx,]
#' x.te <- x[-tr.idx,]
#' y.tr <- y[tr.idx]
#' y.te <- y[-tr.idx]
#' 
#' # GLM with original features
#' glm <- glmnet(x = x.tr, y = y.tr, family = "binomial", lambda = 0)
#' yhat <- drop(predict(glm, x.te, type = "class"))
#' yhat <- factor(yhat, levels = levels(y.tr))
#' classLoss(actual = y.te, predicted = yhat)
#' 
#' set.seed(2048)
#' new.data <- knnExtract(xtr = x.tr, ytr = y.tr, xte = x.te, k = 3)
#' 
#' # GLM with KNN features
#' glm <- glmnet(x = new.data$new.tr, y = y.tr, family = "binomial", lambda = 0)
#' yhat <- drop(predict(glm, new.data$new.te, type = "class"))
#' yhat <- factor(yhat, levels = levels(y.tr))
#' classLoss(actual = y.te, predicted = yhat)
#' }
knnExtract <- function(xtr, ytr, xte, k = 1, normalize = NULL, folds = 5, 
                       nthread = 1) {
   #### Check args
   checkKnnArgs(xtr, ytr, xte, k)
   
   #### Check and create data folds
   if (length(folds) > 1) {
      if (length(unique(folds)) < 3) {
         stop('The smallest number of folds allowable is 3')
      }
      if (length(unique(folds)) > nrow(xtr)) {
         stop('The highest number of folds allowable is nobs (leave-one-out CV)')
      }
   } else {
      folds <- min(max(3, folds), nrow(xtr))
      if (folds > 10) {
         warning("The number of folds is greater than 10. It may take too much time.")
      }
      folds <- createCVFolds(ytr, n = folds)
   }
   nfolds <- length(unique(folds))
   
   #### Parallel computing
   cl <- createCluster(nthread, nfolds)
   
   #### Transform fold ids to factor
   folds <- factor(paste('fold', folds, sep = '_'), 
                   levels = paste('fold', sort(unique(folds)), sep = '_'))
   
   #### Normalize data
   if (!is.null(normalize)) {
      norm.out <- scaleData(xtr, xte, type = normalize)
      xtr <- norm.out$new.tr
      xte <- norm.out$new.te
      rm("norm.out")
      gc()
   }
   
   #### Extract features from training set
   ## n-fold CV is used to avoid overfitting
   message("Building new training set...")
   ## Formater functions
   orderFolds <- function(x) {
      x <- x[order(x[, 1, drop = TRUE]),]
      return(x[,-1,drop = FALSE])
   }
   formatFeatures <- function(x) {
      x <- round(x, 6)
      colnames(x) <- paste0("knn", 1:ncol(x))
      return(x)
   }
   ## Progress bar
   pb <- txtProgressBar(min = 0, max = nfolds * nlevels(ytr), style = 3)
   pb.update <- function(n) setTxtProgressBar(pb, n)
   pb.opts <- list(progress = pb.update)
   ## Iterate over class labels and cv folds
   tr.feat <- foreach::foreach(
      y.label = levels(ytr), 
      .combine = "cbind",
      .final = formatFeatures
   ) %:% foreach::foreach(
      fold.id = levels(folds),
      .combine = "rbind",
      .final = orderFolds,
      .options.snow = pb.opts
   ) %dopar% {
      te.idx <- which(folds == fold.id)
      tr.idx <- base::intersect(
         base::setdiff(1:nrow(xtr), te.idx),
         which(ytr == y.label)
      )
      dist.mat <- RANN::nn2(data = xtr[tr.idx, ], query = xtr[te.idx, ], 
                            k = k, treetype = 'kd', 
                            searchtype = 'standard')$nn.dists
      cbind(te.idx, matrixStats::rowCumsums(dist.mat))
   }
   close(pb)
   
   #### Extract features from test set
   message("Building new test set...")
   ## Progress bar
   pb <- txtProgressBar(min = 0, max = nlevels(ytr), style = 3)
   ## Iterate over class labels
   te.feat <- foreach::foreach(
      y.label = levels(ytr), 
      .combine = "cbind",
      .final = formatFeatures,
      .options.snow = pb.opts
   ) %dopar% {
      idx <- which(ytr == y.label)
      dist.mat <- RANN::nn2(data = xtr[idx, ], query = xte, k = k, 
                            treetype = 'kd', searchtype = 'standard')$nn.dists
      matrixStats::rowCumsums(dist.mat)
   }
   close(pb)
   
   #### Force to free memory
   rm(list = c("xtr", "ytr", "xte"))

   #### Free allocated cores
   closeCluster(cl)
      
   return(list(
      new.tr = tr.feat,
      new.te = te.feat
   ))
}

knnStack <- function(xtr, ytr, xte, k = 10, method = "dist", normalize = NULL, 
                     folds = 5) {
   #### Check args
   checkKnnArgs(xtr, ytr, xte, k)
   
   #### Check and create data folds
   if (length(folds) > 1) {
      if (length(unique(folds)) < 3) {
         stop('The smallest number of folds allowable is 3')
      }
      if (length(unique(folds)) > nrow(xtr)) {
         stop('The highest number of folds allowable is nobs (leave-one-out CV)')
      }
   } else {
      folds <- min(max(3, folds), nrow(xtr))
      if (folds > 10) {
         warning("The number of folds is greater than 10. It may take too much time.")
      }
      folds <- createCVFolds(ytr, n = folds)
   }
   
   #### Transform fold ids to factor
   folds <- factor(paste('fold', folds, sep = '_'), 
                   levels = paste('fold', sort(unique(folds)), sep = '_'))
   
   #### Predict probabilities for the training set
   ## n-fold CV is used to avoid overfitting
   message("Building new training set...")
   tr.prob <- pbapply::pblapply(levels(folds), function(fold.id) {
      val.idx <- which(folds == fold.id)
      val.prob <- fastknn(xtr[-val.idx,], ytr[-val.idx], xtr[val.idx,], k = k, 
                          method = method, normalize = normalize)$prob
      cbind(val.idx, val.prob)
   })
   tr.prob <- do.call('rbind', tr.prob)
   tr.prob <- tr.prob[order(tr.prob[, 1, drop = TRUE]),]
   tr.prob <- tr.prob[, -1, drop = FALSE]
   colnames(tr.prob) <- levels(ytr)
   
   #### Predict probabilities for the test set
   message("Building new test set...")
   te.prob <- fastknn(xtr, ytr, xte, k = k, method = method, 
                      normalize = normalize)$prob
   colnames(te.prob) <- levels(ytr)
   
   #### Force to free memory
   rm(list = c("xtr", "ytr", "xte"))
   gc()
   
   return(list(
      new.tr = tr.prob,
      new.te = te.prob
   ))
}

## ----setup, include=FALSE------------------------------------------------------------------------------------------------------
knitr::opts_chunk$set(echo = TRUE); library(snpR); library(ggplot2); library(data.table); library(foreach); library(doParallel)


## ------------------------------------------------------------------------------------------------------------------------------
# Generate some example data:
## define parameters
seed <- 231233
threads <- 25
allele_frequencies <- seq(.001, .1, by = .001) # allele frequencies
n1 <- 5000 # p1 gene copy number
n2 <- 500 # p2 gene copy number
k <- seq(10, 100, by = 10) # numbers to rarefact to
mcmcs <- seq(1000, 10000, by = 1000) # number of mcmc draws
max_missing <- 30 # maximum percentage of missing data in a locus, from a uniform dist


## derived
set.seed(seed)
nal <- length(allele_frequencies)
miss_percent <- floor(runif(nal, 0, max_missing))/100


## ------------------------------------------------------------------------------------------------------------------------------
# generate genotypes
g1 <- matrix(0, nrow = nal, ncol = n1) # init
g2 <- matrix(0, nrow = nal, ncol = n2)

# add missing data
ms1 <- lapply(n1*miss_percent, function(x) sample(n1, x, FALSE))  # which are missing
ms2 <- lapply(n2*miss_percent, function(x) sample(n2, x, FALSE))

# determine minor allele placements
ma1 <- ma2 <- vector("list", length(ms1))
for(i in 1:nal){
  ma1[[i]] <- sample(n1*(1-miss_percent)[i], (n1*(1-miss_percent)*allele_frequencies)[i], FALSE)
  ma2[[i]] <- sample(n2*(1-miss_percent)[i], (n2*(1-miss_percent)*allele_frequencies)[i], FALSE)

}

# populate
## function to replace minors
populate <- function(g, missing, minors){
  if(length(missing) > 0){
    g[missing] <- NA
    g[-missing][minors] <- 1
  }
  else{
    g[minors] <- 1
  }
  return(g)
}
## do for every locus
for(i in 1:nal){ 
  g1[i,] <- populate(g1[i,], ms1[[i]], ma1[[i]])
  g2[i,] <- populate(g2[i,], ms2[[i]], ma2[[i]])
}

## combine into individuals
g1 <- g1[,1:(ncol(g1)/2)] + g1[,((ncol(g1)/2) + 1):ncol(g1)]
g2 <- g2[,1:(ncol(g2)/2)] + g2[,((ncol(g2)/2) + 1):ncol(g2)]



## ------------------------------------------------------------------------------------------------------------------------------
counts <- function(g){
  return(data.frame(majhom = rowSums(g == 0, na.rm = TRUE), 
                    het = rowSums(g == 1, na.rm = TRUE), 
                    minhom = rowSums(g == 2, na.rm = TRUE)))
}
rarefact <- function(counts, k){
  if(length(k) > 1){
    warning("length(k) > 1, using first element only.\n")
    k <- k[1]
  }
  return(1 - ((choose(counts[,1], k) + choose(counts[,3], k))/choose(rowSums(counts), k)))
}
varseg <- function(p) p*(1-p)

c1 <- counts(g1) # geno counts
c2 <- counts(g2)

# rarefact
pseg1 <- lapply(k, function(tk) rarefact(c1, tk))
pseg2 <- lapply(k, function(tk) rarefact(c2, tk))

vseg1 <- lapply(pseg1, varseg)
vseg2 <- lapply(pseg2, varseg)

p1 <- lapply(pseg1, function(p) sum(p)/nal)
p2 <- lapply(pseg2, function(p) sum(p)/nal)


## ------------------------------------------------------------------------------------------------------------------------------
set.seed(seed) # reset seed for cluster

rarefact_mcmc <- function(g, k){
  if(length(k) > 1){
    warning("length(k) > 1, using first element only.\n")
    k <- k[1]
  }
  
  miss <- is.na(g)
  if(any(miss)){
    g <- g[-which(miss)]
  }
  
  samp <- sample(g, k, FALSE)
  seg <- ifelse(any(samp == 1), 1, # got hets
                ifelse(any(samp == 0) & any(samp == 2), 1, 0)) # got both homs
  return(seg)
}

# draw for each k/mcmc count combination
combs <- expand.grid(k, mcmcs)
colnames(combs) <- c("k", "iters")

cl <- parallel::makePSOCKcluster(threads)
doParallel::registerDoParallel(cl)

mcmc_res <- foreach(q = 1:nrow(combs), 
                    .packages = c("binom", "data.table"), 
                    .export = c("rarefact_mcmc"), 
                    .inorder = FALSE) %dopar% {
  tmcmcs <- combs$iters[q]
  tk <- combs$k[q]
  
  seg1 <- seg2 <- matrix(0, nal, tmcmcs)
  for(i in 1:tmcmcs){
    for(j in 1:nal){
      seg1[j,i] <- rarefact_mcmc(g1[j,], k = tk)
      seg2[j,i] <- rarefact_mcmc(g2[j,], k = tk)
    }
  }
  
  mpseg1 <- binom::binom.confint(rowSums(seg1), rep(mcmcs, nrow(seg1)), 
                                 method = "agresti-coull")[,c("mean", "lower", "upper")]
  mpseg2 <- binom::binom.confint(rowSums(seg2), rep(mcmcs, nrow(seg1)),
                                 method = "agresti-coull")[,c("mean", "lower", "upper")]
  
  colnames(mpseg1) <- colnames(mpseg2) <- c("mean", "lower", "upper")
  
  list(seg1 = seg1, seg2 = seg2, mpseg1 = mpseg1, mpseg2 = mpseg2, k = tk, iters = tmcmcs)
}

parallel::stopCluster(cl)

saveRDS(mcmc_res, "mcmc_res.RDS")



## ------------------------------------------------------------------------------------------------------------------------------



## ------------------------------------------------------------------------------------------------------------------------------
colors <- khroma::color("highcontrast")(3)
ci_col <- as.character(colors[3])
colors <- as.character(colors[c(2,1)])

#========plot the emperical CIs around every loci vs the predicted value==============
# plotting the emperical CIs vs the estiamted mean
pseg <- rbind(data.frame(pop = paste0("n = ", n1/2), p = pseg1, snp = 1:nal, af = allele_frequencies),
              data.frame(pop = paste0("n = ", n2/2), p = pseg2, snp = 1:nal, af = allele_frequencies))

oseg <- rbind(data.frame(pop = paste0("n = ", n1/2), p = mpseg1[,1], snp = 1:nal, af = allele_frequencies),
              data.frame(pop = paste0("n = ", n2/2), p = mpseg2[,1], snp = 1:nal, af = allele_frequencies))

pseg$source <- "Mathematical"
oseg$source <- "Simulation"

seg <- rbind(pseg, oseg)
cis <- rbind(cbind.data.frame(mpseg1, pop = paste0("n = ", n1/2), af = allele_frequencies),
             cbind.data.frame(mpseg2, pop = paste0("n = ", n2/2), af = allele_frequencies))
colnames(cis) <- c("p", "lower", "upper", "pop", "af")
seg <- merge(seg, cis[,c("lower", "upper", "af", "pop")], by = c("af", "pop"))
seg$in_ci <- ifelse(seg$p >= seg$lower & seg$p <= seg$upper, TRUE, FALSE)

f1 <- ggplot(seg[seg$source == "Mathematical",],
             aes(x = af, y = p)) +
  geom_point(aes(color = in_ci)) +
  geom_errorbar(aes(ymax = upper, ymin = lower)) +
  facet_wrap(~pop) +
  theme_bw() +
  theme(strip.background = element_blank()) +
  scale_color_manual(values = colors) +
  guides(color = guide_legend(title = "In CI")) +
  ylab(bquote(italic(P*"("*S[jq]*")"))) +
  xlab("Minor Allele Frequency")

ggsave("Figure1.pdf", f1, width = 14, height = 7)

tapply(seg[seg$source == "Mathematical", "in_ci"], seg$pop[seg$source == "Mathematical"], mean) # percent in interval
#===============plot all of the observed values vs the estimated value for the sums=============
# plot the estimated prediction interval vs the observations and the confint from the simultations
nap_pi <- function(alpha, vseg, n) qnorm(1 - (alpha/2))*sqrt(vseg)*sqrt(1 + (1/n))
nap_ci <- function(alpha, vseg, n) qnorm(1 - (alpha/2))*sqrt(vseg)/sqrt(n)

# sums across loci
msum1 <- colSums(seg1)
msum2 <- colSums(seg2)

# CI/PI
msum_ci1 <- nap_ci(.05, var(msum1), length(msum1))
msum_ci2 <- nap_ci(.05, var(msum2), length(msum2))

sum_pi1 <- nap_pi(0.05, sum(vseg1), nal)
sum_pi2 <- nap_pi(0.05, sum(vseg2), nal)

# add to table
msum_tab <- data.frame(nseg = c(mean(msum1), mean(msum2)),
                       lower = c(mean(msum1) - msum_ci1, mean(msum2) - msum_ci2),
                       upper = c(mean(msum1) + msum_ci1, mean(msum2) + msum_ci2),
                       pop = c(paste0("n = ", n1/2), paste0("n = ", n2/2)))

sum_tab <- tapply(seg[seg$source == "Mathematical",]$p, seg[seg$source == "Mathematical",]$pop, sum)
sum_tab <- as.data.frame(sum_tab)
sum_tab$pop <- rownames(sum_tab)
colnames(sum_tab)[1] <- "nseg"
sum_tab <- merge(sum_tab, msum_tab[,c("pop", "lower", "upper")], by = "pop")
sum_tab$in_ci <- sum_tab$nseg <= sum_tab$upper & sum_tab$nseg >= sum_tab$lower

# add pi
all_mcmc_sums <- rbind(cbind.data.frame(nseg = msum1, pop = paste0("n = ", n1/2)),
                   cbind.data.frame(nseg = msum2, pop = paste0("n = ", n2/2)))
pi_tab <- data.frame(pop = c(paste0("n = ", n1/2), paste0("n = ", n2/2)),
                     lower = c(sum_tab$nseg[sum_tab$pop == paste0("n = ", n1/2)] - sum_pi1,
                               sum_tab$nseg[sum_tab$pop == paste0("n = ", n2/2)] - sum_pi2),
                     upper = c(sum_tab$nseg[sum_tab$pop == paste0("n = ", n1/2)] + sum_pi1,
                               sum_tab$nseg[sum_tab$pop == paste0("n = ", n2/2)] + sum_pi2))
all_mcmc_sums <- merge(all_mcmc_sums, pi_tab, by = "pop")
all_mcmc_sums$in_pi <- all_mcmc_sums$nseg <=  all_mcmc_sums$upper & all_mcmc_sums$nseg >=  all_mcmc_sums$lower

Figure2 <- ggplot(sum_tab, aes(x = pop, y = nseg, color = in_ci)) + 
  geom_jitter(data = all_mcmc_sums, aes(x = pop, y = nseg, color = in_pi), height = 0, alpha = .2) +
  geom_point(size = 4, shape = 17) +
  geom_errorbar(data = sum_tab, aes(ymax = upper, ymin = lower, x = pop), 
                inherit.aes = FALSE, width = .25, color = ci_col, linewidth = 1) +
  geom_errorbar(data = pi_tab, aes(ymax = upper, ymin = lower, x = pop), 
                inherit.aes = FALSE, width = .5, linetype = "dashed", color = ci_col, linewidth = 1) +
  theme_bw() +
  theme(strip.background = element_blank()) +
  scale_color_manual(values = colors) +
  guides(color = guide_legend(title = "In CI/PI")) +
  ylab(bquote(italic(E*"("*N[S]*")"))) +
  xlab("Population")

ggsave("Figure2.pdf", Figure2, height = 7, width = 14)

tapply(all_mcmc_sums$in_pi, all_mcmc_sums$pop, mean, na.rm = TRUE)

#==========others==================

# variances, per locus
vars <- rbind(cbind.data.frame(estimated = vseg1, 
                               observed = matrixStats::rowVars(seg1),
                               pop = paste0("n = ", n1/2),
                               af = allele_frequencies),
              cbind.data.frame(estimated = vseg2, 
                               observed = matrixStats::rowVars(seg2),
                               pop = paste0("n = ", n2/2),
                               af = allele_frequencies))
ggplot(vars, aes(x = observed, y = estimated, color = af)) +
  geom_point() +
  geom_abline(intercept = 0, slope = 1) +
  facet_wrap(~pop) +
  theme_bw() +
  khroma::scale_color_batlow()

# variances, overall
overall_vars <- rbind(cbind.data.frame(estimated = sum(vseg1),
                                       observed = var(msum1),
                                       pop = paste0("n = ", n1/2)),
                      cbind.data.frame(estimated = sum(vseg2),
                                       observed = var(msum2),
                                       pop = paste0("n = ", n2/2)))


## ------------------------------------------------------------------------------------------------------------------------------
# show difference in HWE divergence with different combinations of 5 minor alleles in 100 genotypes
exd <- rbind(c(rep(0, 45), rep(1, 5)),
             c(rep(0, 46), 2, rep(1, 3)),
             c(rep(0, 47), rep(2, 2), 1))
exds <- import.snpR.data(as.data.frame(exd), snp.meta = data.frame(snp = 1:3), mDat = -9)
exds <- calc_hwe(exds)
get.snpR.stats(exds, stats = "hwe")

exc <- counts(exd)
rarefact(exc, 10)


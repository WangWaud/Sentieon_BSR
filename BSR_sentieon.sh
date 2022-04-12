#!/bin/sh
module load sentieon/202112
set -eu

# Update with the fullpath location of your sample fastq
SM="ZM895" #sample name
RGID="rg_$SM" #read group ID
PL="ILLUMINA" #or other sequencing platform
FASTQ_FOLDER="/public/home/hychao/LZM/data"
FASTQ_1="$FASTQ_FOLDER/ZM895_FRAS220033950-2r_1.clean.fq.gz"
FASTQ_2="$FASTQ_FOLDER/ZM895_FRAS220033950-2r_2.clean.fq.gz" #If using Illumina paired data

# Update with the location of the reference data files
FASTA_DIR="/public/home/hychao/LZM/genome_gtf"
FASTA="$FASTA_DIR/Triticum_aestivum.IWGSC.dna.toplevel.fa"

#comment if STAR should generate a new genomeDir
STAR_FASTA="$FASTA_DIR/Triticum_aestivum.IWGSC.dna.toplevel.fa.genomeDir"
#uncomment if you would like to use a bed file
#INTERVAL_FILE="$FASTA_DIR/TruSeq_exome_targeted_regions.b37.bed"

# Other settings
#NT=$(nproc) #number of threads to use in computation, set to number of cores in the server
NT=16
START_DIR="/public/home/hychao/LZM/test" #Determine where the output files will be stored



# You do not need to modify any of the lines below unless you want to tweak the pipeline

# ************************************************************************************************************************************************************************

# ******************************************
# 0. Setup
# ******************************************
WORKDIR="$START_DIR/${SM}"
mkdir -p $WORKDIR
LOGFILE=$WORKDIR/run.log
exec >$LOGFILE 2>&1
cd $WORKDIR
DRIVER_INTERVAL_OPTION="${INTERVAL_FILE:+--interval $INTERVAL_FILE}"

# ******************************************
# 1. Mapping reads with STAR
# ******************************************
if [ -z "$STAR_FASTA" ]; then
  STAR_FASTA="genomeDir"
  # The genomeDir generation could be reused
  mkdir $STAR_FASTA
  sentieon STAR --runMode genomeGenerate \
      --genomeDir $STAR_FASTA --genomeFastaFiles $FASTA --runThreadN $NT || \
      { echo "STAR index failed"; exit 1; }
fi
#perform the actual alignment and sorting
( sentieon STAR --twopassMode Basic --genomeDir $STAR_FASTA \
    --runThreadN $NT --outStd BAM_Unsorted --outSAMtype BAM Unsorted \
    --outBAMcompression 0 --twopass1readsN -1  \
    --readFilesIn $FASTQ_1 $FASTQ_2 --readFilesCommand "zcat" \
    --outSAMattrRGline ID:$RGID SM:$SM PL:$PL || { echo -n 'STAR error'; exit 1; } ) | \
    sentieon util sort -r $FASTA -o sorted.bam \
    -t $NT --bam_compression 1 -i - || { echo "STAR alignment failed"; exit 1; }

# ******************************************
# 2. Metrics
# ******************************************
sentieon driver $DRIVER_INTERVAL_OPTION -r $FASTA -t $NT \
    -i sorted.bam --algo MeanQualityByCycle mq_metrics.txt --algo QualDistribution \
    qd_metrics.txt --algo GCBias --summary gc_summary.txt gc_metrics.txt \
    --algo AlignmentStat --adapter_seq '' aln_metrics.txt --algo InsertSizeMetricAlgo \
    is_metrics.txt || { echo "Metrics failed"; exit 1; }

sentieon plot GCBias -o gc-report.pdf gc_metrics.txt
sentieon plot QualDistribution -o qd-report.pdf qd_metrics.txt
sentieon plot MeanQualityByCycle -o mq-report.pdf mq_metrics.txt
sentieon plot InsertSizeMetricAlgo -o is-report.pdf is_metrics.txt

# ******************************************
# 3. Remove Duplicate Reads. It is possible
# to remove instead of mark duplicates
# by adding the --rmdup option in Dedup
# ******************************************
sentieon driver -t $NT -i sorted.bam --algo LocusCollector \
    --fun score_info score.txt || { echo "LocusCollector failed"; exit 1; }

sentieon driver -t $NT -i sorted.bam --algo Dedup \
    --score_info score.txt --metrics dedup_metrics.txt deduped.bam || \
    { echo "Dedup failed"; exit 1; }

# ******************************************
# 2a. Coverage metrics
# ******************************************
sentieon driver -r $FASTA -t $NT -i deduped.bam \
    --algo CoverageMetrics coverage_metrics || { echo "CoverageMetrics failed"; exit 1; }

# ******************************************
# 4. Split reads at Junction
# ******************************************
sentieon driver -r $FASTA -t $NT -i deduped.bam \
    --algo RNASplitReadsAtJunction --reassign_mapq 255:60 splitted.bam || \
    { echo "RNASplitReadsAtJunction failed"; exit 1; }

# ******************************************
# 6. Base recalibration
# ******************************************
sentieon driver $DRIVER_INTERVAL_OPTION -r $FASTA -t $NT \
    -i splitted.bam --algo QualCal \
    recal_data.table
sentieon driver $DRIVER_INTERVAL_OPTION -r $FASTA -t $NT \
    -i splitted.bam --algo QualCal \
    recal_data.table.post
sentieon driver -t $NT --algo QualCal --plot \
    --before recal_data.table --after recal_data.table.post recal.csv
sentieon plot QualCal -o recal_plots.pdf recal.csv

# ******************************************
# 7. HC Variant caller for RNA
# ******************************************
sentieon driver $DRIVER_INTERVAL_OPTION -r $FASTA -t $NT \
    -i splitted.bam --algo Haplotyper  \
    --trim_soft_clip --emit_conf=20 --call_conf=20 output-hc-rna.vcf.gz || \
    { echo "Haplotyper failed"; exit 1; }

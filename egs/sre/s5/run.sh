#!/bin/bash
# 
# This script is similar with egs/fisher_english
# Generate the ASR acoustic model and alignments for other use.
# The number of senones used in our system is about 4K. It is 
# 


. ./cmd.sh
. ./path.sh
set -e

root=/mnt/lv10/person/liuyi/sre.full/
data=$root/data
exp=$root/exp
mfccdir=$root/mfcc
rescore=true

stage=0

# check for kaldi_lm
which get_word_map.pl > /dev/null
if [ $? -ne 0 ]; then
  echo "This recipe requires installation of tools/kaldi_lm. Please run extras/kaldi_lm.sh in tools/" && exit 1;
fi

if [ $stage -le 0 ]; then
  # prepare fisher data and put it under data/train_fisher
  local/fisher_data_prep.sh $data/train_fisher /mnt/lv10/person/sre16/data/fisher
fi


if [ $stage -le 1 ]; then 
  local/swbd1_data_download.sh /mnt/lv10/person/liuyi/ly_database/Switchboard-P1 $data
  # prepare dictionary and acronym mapping list
  local/fisher_swbd_prepare_dict.sh $data $data/train_fisher
  # prepare swbd data and put it under data/train_swbd
  local/swbd1_data_prep.sh $data /mnt/lv10/person/liuyi/ly_database/LDC97S62
fi

if [ $stage -le 2 ]; then
  utils/prepare_lang.sh $data/local/dict_nosp \
      "<unk>" $data/local/lang_nosp $data/lang_nosp
  
  # merge two datasets into one
  mkdir -p $data/train_all
  for f in spk2utt utt2spk wav.scp text segments reco2file_and_channel; do
    cat $data/train_fisher/$f $data/train_swbd/$f > $data/train_all/$f
  done
  
  # LM for train_all
  local/fisher_train_lms.sh $data

  #local/fisher_create_test_lang.sh
  # Compiles G for trigram LM
  LM=$data/local/lm/3gram-mincount/lm_unpruned.gz
  srilm_opts="-subset -prune-lowprobs -unk -tolower -order 3"
  utils/format_lm_sri.sh --srilm-opts "$srilm_opts" \
    $data/lang_nosp $LM $data/local/dict_nosp/lexicon.txt $data/lang_nosp_fsh_sw1_tg
  
  LM_fg=$data/local/lm/4gram-mincount/lm_unpruned.gz
  [ -f $LM_fg ] || rescore=false
  if [ $rescore ]; then
    utils/build_const_arpa_lm.sh $LM_fg $data/lang_nosp $data/lang_nosp_fsh_sw1_fg
  fi
fi

if [ $stage -le 3 ]; then 
  utils/combine_data.sh $data/train_all $data/train_fisher $data/train_swbd
  utils/fix_data_dir.sh $data/train_all

  # Make MFCCs for the training set
  steps/make_mfcc.sh --nj 32 --cmd "$train_cmd" $data/train_all $exp/make_mfcc/train_all $mfccdir || exit 1;
  utils/fix_data_dir.sh $data/train_all
  utils/validate_data_dir.sh $data/train_all
  steps/compute_cmvn_stats.sh $data/train_all $exp/make_mfcc/train_all $mfccdir
  
  # subset swbd features and put them back into train_swbd in case separate training is needed
  awk -F , '{print $1}' $data/train_swbd/spk2utt > $data/swbd_spklist
  utils/subset_data_dir.sh --spk-list $data/swbd_spklist $data/train_all $data/train_swbd
  steps/compute_cmvn_stats.sh $data/train_swbd $exp/make_mfcc/train_swbd $mfccdir
  
  n=$[`cat $data/train_all/segments | wc -l`]
  echo $n
  utils/subset_data_dir.sh --last $data/train_all $n $data/train
fi


if [ $stage -le 4 ]; then
 # Now-- there are 2.1 million utterances, and we want to start the monophone training
 # on relatively short utterances (easier to align), but not only the very shortest
 # ones (mostly uh-huh).  So take the 100k shortest ones, and then take 10k random
 # utterances from those. We also take these subsets from Switchboard, which has
 # more carefully hand-labeled alignments
 
 utils/subset_data_dir.sh --shortest $data/train_swbd 100000 $data/train_100kshort
 utils/data/remove_dup_utts.sh 10 $data/train_100kshort $data/train_100kshort_nodup
 utils/subset_data_dir.sh  $data/train_100kshort_nodup 10000 $data/train_10k_nodup
 
 utils/subset_data_dir.sh --speakers $data/train_swbd 30000 $data/train_30k
 utils/subset_data_dir.sh --speakers $data/train_swbd 100000 $data/train_100k
 
 utils/data/remove_dup_utts.sh 200 $data/train_30k $data/train_30k_nodup
 utils/data/remove_dup_utts.sh 200 $data/train_100k $data/train_100k_nodup
 utils/data/remove_dup_utts.sh 300 $data/train $data/train_nodup
fi 

if [ $stage -le 5 ]; then
  # Start training on the Switchboard subset, which has cleaner alignments
  steps/train_mono.sh --nj 3 --cmd "$train_cmd" \
    $data/train_10k_nodup $data/lang_nosp $exp/mono0a
  
  steps/align_si.sh --nj 10 --cmd "$train_cmd" \
     $data/train_30k_nodup $data/lang_nosp $exp/mono0a $exp/mono0a_ali || exit 1;
  
  steps/train_deltas.sh --cmd "$train_cmd" \
      3200 30000 $data/train_30k_nodup $data/lang_nosp $exp/mono0a_ali $exp/tri1a || exit 1;
  steps/align_si.sh --nj 10 --cmd "$train_cmd" \
     $data/train_30k_nodup $data/lang_nosp $exp/tri1a $exp/tri1a_ali || exit 1;
  
  steps/train_deltas.sh --cmd "$train_cmd" \
      3200 30000 $data/train_30k_nodup $data/lang_nosp $exp/tri1a_ali $exp/tri1b || exit 1;
  steps/align_si.sh --nj 32 --cmd "$train_cmd" \
     $data/train_100k_nodup $data/lang_nosp $exp/tri1b $exp/tri1b_ali || exit 1;
  
  steps/train_deltas.sh --cmd "$train_cmd" \
      5500 90000 $data/train_100k_nodup $data/lang_nosp $exp/tri1b_ali $exp/tri2 || exit 1;
fi

if [ $stage -le 6 ]; then
  # Train tri3a, the last speaker-independent triphone stage,
  # on the whole Switchboard training set
  steps/align_si.sh --nj 32 --cmd "$train_cmd" \
     $data/train_swbd $data/lang_nosp $exp/tri2 $exp/tri2_ali || exit 1;
  
  steps/train_deltas.sh --cmd "$train_cmd" \
      11500 200000 $data/train_swbd $data/lang_nosp $exp/tri2_ali $exp/tri3a || exit 1;
  
  # Train tri3b, which is LDA+MLLT on the whole Switchboard+Fisher training set
  steps/align_si.sh --nj 32 --cmd "$train_cmd" \
    $data/train_nodup $data/lang_nosp $exp/tri3a $exp/tri3a_ali || exit 1;
  
  steps/train_lda_mllt.sh --cmd "$train_cmd" \
     --splice-opts "--left-context=3 --right-context=3" \
     11500 400000 $data/train_nodup $data/lang_nosp $exp/tri3a_ali $exp/tri3b || exit 1;
fi 

if [ $stage -le 7 ]; then
  steps/get_prons.sh --cmd "$train_cmd" $data/train_nodup $data/lang_nosp $exp/tri3b
  
  utils/dict_dir_add_pronprobs.sh --max-normalize true \
    $data/local/dict_nosp $exp/tri3b/pron_counts_nowb.txt $exp/tri3b/sil_counts_nowb.txt \
    $exp/tri3b/pron_bigram_counts_nowb.txt $data/local/dict
  
  utils/prepare_lang.sh $data/local/dict "<unk>" $data/local/lang $data/lang
  
  LM=$data/local/lm/3gram-mincount/lm_unpruned.gz
  srilm_opts="-subset -prune-lowprobs -unk -tolower -order 3"
  utils/format_lm_sri.sh --srilm-opts "$srilm_opts" \
    $data/lang $LM $data/local/dict/lexicon.txt $data/lang_fsh_sw1_tg
  
  LM_fg=$data/local/lm/4gram-mincount/lm_unpruned.gz
  if [ $rescore ]; then
    utils/build_const_arpa_lm.sh $LM_fg $data/lang $data/lang_fsh_sw1_fg
  fi
fi 

if [ $stage -le 8 ]; then 
  # Next we'll use fMLLR and train with SAT (i.e. on
  # fMLLR features)
  steps/align_fmllr.sh --nj 32 --cmd "$train_cmd" \
    $data/train_nodup $data/lang $exp/tri3b $exp/tri3b_ali || exit 1;
  
  steps/train_sat.sh  --cmd "$train_cmd" \
    11500 800000 $data/train_nodup $data/lang $exp/tri3b_ali $exp/tri4a || exit 1;
  
  steps/align_fmllr.sh --nj 32 --cmd "$train_cmd" \
    $data/train_nodup $data/lang $exp/tri4a $exp/tri4a_ali || exit 1;
  
  steps/train_sat.sh  --cmd "$train_cmd" \
    11500 1600000 $data/train_nodup $data/lang $exp/tri4a_ali $exp/tri5a || exit 1;
  
  hours=$(awk '{x += $4 - $3;} END{print x/3600;}' <$data/train_fisher/segments)
  ! [ $hours == 1915 ] && echo "$0: expected 1915 hours of data, got $hours hours, please check." && exit 1;
  
  steps/align_fmllr.sh --nj 32 --cmd "$train_cmd" \
    $data/train_nodup $data/lang $exp/tri5a $exp/tri5a_ali || exit 1;
fi

if [ $stage -le 9 ]; then
  # steps/train_sat.sh  --cmd "$train_cmd" \
  #   11500 3200000 $data/train_nodup $data/lang $exp/tri5a_ali $exp/tri6a_10k || exit 1;

  # steps/align_fmllr.sh --nj 32 --cmd "$train_cmd" \
  #   $data/train_nodup $data/lang $exp/tri6a_10k $exp/tri6a_10k_ali || exit 1;

  steps/train_sat.sh  --cmd "$train_cmd" \
    5000 400000 $data/train_nodup $data/lang $exp/tri5a_ali $exp/tri6a_4k || exit 1;
  
  steps/align_fmllr.sh --nj 32 --cmd "$train_cmd" \
    $data/train_nodup $data/lang $exp/tri6a_4k $exp/tri6a_4k_ali || exit 1;
fi 


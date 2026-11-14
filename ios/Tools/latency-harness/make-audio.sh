#!/bin/zsh
# Generates the test phrases with the macOS voices (16 kHz mono 16-bit WAV, one file per phrase) and a
# list.tsv per language: path \t reference text. The harness lays them out on a timeline itself (silence
# between them), so it knows where every phrase starts and ends.
#   EN_VOICE=Samantha VI_VOICE=Linh ./make-audio.sh [outdir]
set -e
here=${0:A:h}
out=${1:-$here/audio}
en_voice=${EN_VOICE:-Samantha}
vi_voice=${VI_VOICE:-Linh}

en=(
  "Good evening, do you have a reservation?"
  "Your room is on the fifth floor, the elevator is to the left."
  "Breakfast is served from six thirty to ten."
  "Where would you like to go?"
  "It will take about twenty minutes because of the traffic."
  "That will be fifteen dollars, please."
  "How long have you had this pain?"
  "Take one tablet twice a day after meals."
  "Would you like a bag for that?"
  "We accept cash and all major credit cards."
  "If you are allergic to any medicine, please tell me now, because the antibiotic I am going to prescribe can cause a reaction in some patients."
  "The airport shuttle leaves from the main entrance every thirty minutes, but tonight the last one is at eleven, so I recommend booking a taxi instead."
)
vi=(
  "Xin chào, tôi đã đặt phòng tên Nguyễn."
  "Cho tôi hỏi mấy giờ trả phòng?"
  "Làm ơn chở tôi đến sân bay."
  "Đi hết bao nhiêu tiền vậy?"
  "Tôi bị đau bụng từ tối hôm qua."
  "Tôi bị dị ứng với thuốc kháng sinh."
  "Cái áo này giá bao nhiêu?"
  "Có cỡ nhỏ hơn không?"
  "Tôi muốn trả bằng thẻ."
  "Cảm ơn anh rất nhiều."
  "Tôi cần đổi phòng vì máy lạnh trong phòng không hoạt động và tối qua tôi không ngủ được."
  "Anh có thể đợi tôi khoảng mười phút ở đây rồi chở tôi quay lại khách sạn được không?"
)

gen() {  # lang voice phrases…
  local lang=$1 voice=$2; shift 2
  mkdir -p $out/$lang
  : > $out/$lang/list.tsv
  local i=1
  for p in "$@"; do
    local f=$out/$lang/$(printf %02d $i).wav
    say -v $voice -o $f --file-format=WAVE --data-format=LEI16@16000 "$p"
    printf '%s\t%s\n' ${f:t} "$p" >> $out/$lang/list.tsv
    i=$((i + 1))
  done
  echo "$lang: $((i - 1)) phrases ($voice) in $out/$lang"
}
say -v '?' | grep -q "^$en_voice " || { echo "voice $en_voice not installed"; exit 1; }
say -v '?' | grep -q "^$vi_voice " || { echo "voice $vi_voice not installed (say -v '?' | grep vi_VN)"; exit 1; }
gen en $en_voice "${en[@]}"
gen vi $vi_voice "${vi[@]}"

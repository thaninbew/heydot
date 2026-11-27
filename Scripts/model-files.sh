# Sourced by the dependency fetcher and the app assembly script.
MODEL=sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01
MODEL_FILES=(tokens.txt bpe.model {encoder,decoder,joiner}-epoch-12-avg-2-chunk-16-left-64.int8.onnx)

has_model_files() {
  local file
  for file in "${MODEL_FILES[@]}"; do
    [[ -s "$1/$file" ]] || return 1
  done
}

#!/usr/bin/env bash
set -Eeuo pipefail

: "${MODEL_NAME:?MODEL_NAME is required}"
: "${HOST:?HOST is required}"
: "${PORT:?PORT is required}"
: "${RUN_DIR:?RUN_DIR is required}"
: "${BENCH_PAIRS:?BENCH_PAIRS is required}"
: "${BENCH_CONCURRENCIES:?BENCH_CONCURRENCIES is required}"
: "${CONCURRENCY_MULTIPLIER:?CONCURRENCY_MULTIPLIER is required}"

[[ "$CONCURRENCY_MULTIPLIER" =~ ^[1-9][0-9]*$ ]] || {
  echo "CONCURRENCY_MULTIPLIER must be a positive integer" >&2
  exit 2
}

ALL_LOG="${RUN_DIR}/all.csv"
printf '%s\n' \
  "input,output,request_rate,num_prompts,max_concurrency,concurrency,Peak_concurrent_requests,duration_s,rps,generate_throughput_tok_s,total_throughput_tok_s,Peak_output_token_throughput,mean_ttft_ms,p95_ttft_ms,p99_ttft_ms,mean_tpot_ms,p95_tpot_ms,p99_tpot_ms,mean_itl_ms,p95_itl_ms,p99_itl_ms" \
  >"$ALL_LOG"

extract_metric() {
  local label=$1 log_file=$2
  awk -v label="$label" '
    index($0, label) == 1 {
      line=$0
      sub(/^[^:]*:[[:space:]]*/, "", line)
      split(line, fields, /[[:space:]]+/)
      print fields[1]
      exit
    }
  ' "$log_file"
}

IFS=',' read -r -a pairs <<<"$BENCH_PAIRS"
IFS=',' read -r -a concurrencies <<<"$BENCH_CONCURRENCIES"

for pair in "${pairs[@]}"; do
  read -r prompt_tokens completion_tokens extra <<<"$pair"
  [[ "$prompt_tokens" =~ ^[1-9][0-9]*$ && "$completion_tokens" =~ ^[1-9][0-9]*$ && -z "${extra:-}" ]] || {
    echo "Invalid BENCH_PAIRS item: $pair" >&2
    exit 2
  }

  for batch in "${concurrencies[@]}"; do
    batch=${batch//[[:space:]]/}
    [[ "$batch" =~ ^[1-9][0-9]*$ ]] || {
      echo "Invalid BENCH_CONCURRENCIES item: $batch" >&2
      exit 2
    }

    num_prompts=$((batch * CONCURRENCY_MULTIPLIER))
    log_file="${RUN_DIR}/${MODEL_NAME}-${batch}-in${prompt_tokens}-out${completion_tokens}.log"
    output_file="${RUN_DIR}/${MODEL_NAME}-${batch}-in${prompt_tokens}-out${completion_tokens}.jsonl"
    echo "Running input=${prompt_tokens}, output=${completion_tokens}, concurrency=${batch}, prompts=${num_prompts}"

    python3 -m sglang.bench_serving \
      --backend sglang \
      --base-url "http://${HOST}:${PORT}" \
      --host "$HOST" \
      --port "$PORT" \
      --tokenizer "$MODEL_PATH" \
      --dataset-name random-ids \
      --random-range-ratio 1 \
      --random-input-len "$prompt_tokens" \
      --random-output-len "$completion_tokens" \
      --request-rate inf \
      --max-concurrency "$batch" \
      --num-prompts "$num_prompts" \
      --output-file "$output_file" \
      2>&1 | tee "$log_file"

    request_rate=$(extract_metric "Traffic request rate" "$log_file")
    concurrency=$(extract_metric "Successful requests" "$log_file")
    peak_concurrent=$(extract_metric "Peak concurrent requests" "$log_file")
    duration=$(extract_metric "Benchmark duration" "$log_file")
    request_throughput=$(extract_metric "Request throughput" "$log_file")
    output_throughput=$(extract_metric "Output token throughput" "$log_file")
    total_throughput=$(extract_metric "Total token throughput" "$log_file")
    peak_output_throughput=$(extract_metric "Peak output token throughput" "$log_file")
    mean_ttft=$(extract_metric "Mean TTFT" "$log_file")
    p95_ttft=$(extract_metric "P95 TTFT" "$log_file")
    p99_ttft=$(extract_metric "P99 TTFT" "$log_file")
    mean_tpot=$(extract_metric "Mean TPOT" "$log_file")
    p95_tpot=$(extract_metric "P95 TPOT" "$log_file")
    p99_tpot=$(extract_metric "P99 TPOT" "$log_file")
    mean_itl=$(extract_metric "Mean ITL" "$log_file")
    p95_itl=$(extract_metric "P95 ITL" "$log_file")
    p99_itl=$(extract_metric "P99 ITL" "$log_file")

    printf '%s\n' \
      "$prompt_tokens,$completion_tokens,$request_rate,$num_prompts,$batch,$concurrency,$peak_concurrent,$duration,$request_throughput,$output_throughput,$total_throughput,$peak_output_throughput,$mean_ttft,$p95_ttft,$p99_ttft,$mean_tpot,$p95_tpot,$p99_tpot,$mean_itl,$p95_itl,$p99_itl" \
      >>"$ALL_LOG"
  done
done

echo "Benchmark results: $ALL_LOG"
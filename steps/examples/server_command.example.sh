export SGLANG_ENABLE_SPEC_V2=1
export SGLANG_USE_FUSED_TOPK_SOFTMAX=1
export SGLANG_USE_LIGHTOP=1
export SGLANG_USE_CAUSAL_CONV1D=1
export SGLANG_USE_AITER_LINEAR_ATTN=1
export SGLANG_USE_CUDA_IPC_TRANSPORT=1
export SGLANG_ROCM_USE_AITER_MOE=true
export SGLANG_USE_FP8_W8A8_MOE=0
sglang serve \
  --model-path /models/qwen3.6/Qwen3.6-35B-A3B-Channel-fp8 \
  --dtype bfloat16 \
  --attention-backend fa3 \
  --mm-attention-backend fa3 \
  --mem-fraction-static 0.9 \
  --port 30099 \
  --page-size 64 \
  --tp-size 2 \
  --pp-size 1 \
  --trust-remote-code \
  --speculative-algorithm EAGLE \
  --enable-piecewise-cuda-graph \
  --speculative-num-steps 3 \
  --speculative-eagle-topk 1 \
  --speculative-num-draft-tokens 4 \
  --mamba-scheduler-strategy extra_buffer \
  --chunked-prefill-size -1 \
  --kv-cache-dtype fp8_e4m3 \
  --tool-call-parser qwen3_coder \
  --reasoning-parser qwen3

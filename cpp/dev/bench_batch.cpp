/*
 * bench_batch.cpp — 并行 batch 延迟对比
 */
#define NOMINMAX
#include "llama.h"
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

static const char * MODEL_PATH = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static const int N_CTX = 64, N_SEQ_MAX = 9;

static std::vector<llama_token> tokenize(const llama_vocab * v, const char * t) {
    std::vector<llama_token> toks(128);
    int n = llama_tokenize(v, t, (int)strlen(t), toks.data(), 128, true, true);
    if (n < 0) { toks.resize(-n); n = llama_tokenize(v, t, (int)strlen(t), toks.data(), (int)toks.size(), true, true); }
    toks.resize(n>0?n:0); return toks;
}

static double bench_config(llama_context * ctx, const llama_vocab * vocab,
    const std::vector<llama_token> & ctx_ids, int n_cands,
    const std::vector<std::vector<llama_token>> & cands_all) {
    std::vector<std::vector<llama_token>> cts;
    for (int i=0;i<n_cands;i++) cts.push_back(cands_all[i]);

    int ctx_len=(int)ctx_ids.size(), total=n_cands*ctx_len;
    for(auto&c:cts)total+=(int)c.size();

    llama_batch batch=llama_batch_init(total,0,N_SEQ_MAX);
    int idx=0;
    for(int i=0;i<n_cands;i++){
        for(int j=0;j<ctx_len;j++){
            batch.token[idx]=ctx_ids[j];batch.pos[idx]=j;
            batch.n_seq_id[idx]=1;batch.seq_id[idx][0]=i;idx++;
        }
        for(int j=0;j<(int)cts[i].size();j++){
            batch.token[idx]=cts[i][j];batch.pos[idx]=ctx_len+j;
            batch.n_seq_id[idx]=1;batch.seq_id[idx][0]=i;
            batch.logits[idx]=1;idx++;
        }
    }
    batch.n_tokens=idx;

    // warmup
    llama_memory_clear(llama_get_memory(ctx),true);
    llama_decode(ctx,batch);

    // timed
    LARGE_INTEGER f,c; QueryPerformanceFrequency(&f);
    const int N=50;
    QueryPerformanceCounter(&c); double t0=c.QuadPart*1000.0/f.QuadPart;
    for(int t=0;t<N;t++){ llama_memory_clear(llama_get_memory(ctx),true); llama_decode(ctx,batch); }
    QueryPerformanceCounter(&c); double dt=c.QuadPart*1000.0/f.QuadPart-t0;
    llama_batch_free(batch);
    return dt/N;
}

static double now_ms(){LARGE_INTEGER f,c;QueryPerformanceFrequency(&f);QueryPerformanceCounter(&c);return c.QuadPart*1000.0/f.QuadPart;}

int main() {
    llama_model_params mp=llama_model_default_params();mp.use_mmap=1;
    llama_model*model=llama_model_load_from_file(MODEL_PATH,mp);
    if(!model){printf("ERROR\n");return 1;}
    const llama_vocab*vocab=llama_model_get_vocab(model);

    const char*LONG_CTX="上半年快递业务量突破八百亿件创历史新高一季度经济数据公布引发关注";
    auto full_ids=tokenize(vocab,LONG_CTX);
    const char*WORDS[]={"突破","增强","数据","市场","历史","政策","发展","稳定","创新"};

    // prep all candidate tokenizations
    std::vector<std::vector<llama_token>> cands_all;
    for(int i=0;i<9;i++)cands_all.push_back(tokenize(vocab,WORDS[i]));

    // test thread configs
    int configs[][2]={{8,8},{14,14},{14,20},{20,20}};
    const char*labels[]={"8t/8b  ","14t/14b","14t/20b","20t/20b"};

    printf("=== Parallel batch latency (ms, 50 iters avg) ===\n\n");

    // Header: ctx vs cand matrix, for each thread config
    printf("%8s",""); for(int c=2;c<=6;c++)printf("%6dcand",c); printf("\n");

    for(int ci=0;ci<4;ci++){
        llama_context_params cp=llama_context_default_params();
        cp.n_ctx=N_CTX;cp.n_threads=configs[ci][0];cp.n_threads_batch=configs[ci][1];
        cp.n_seq_max=N_SEQ_MAX;
        llama_context*ctx=llama_new_context_with_model(model,cp);
        if(!ctx)continue;
        auto wup=tokenize(vocab,"\n");
        if(!wup.empty()){llama_batch b=llama_batch_get_one(wup.data(),(int)wup.size());llama_decode(ctx,b);}

        printf("\n--- %s ---\n",labels[ci]);
        for(int ctx_t=2;ctx_t<=6;ctx_t++){
            auto cids=std::vector<llama_token>(full_ids.end()-ctx_t,full_ids.end());
            printf("tok=%-2d ",ctx_t);
            for(int nc=2;nc<=6;nc++){
                double ms=bench_config(ctx,vocab,cids,nc,cands_all);
                printf(" %6.1f",ms);fflush(stdout);
            }
            printf("\n");
        }
        llama_free(ctx);
    }
    llama_model_free(model);
    printf("\nDone.\n");
    return 0;
}

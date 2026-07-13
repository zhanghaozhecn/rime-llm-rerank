/* bench_train.cpp — 真实打字语料首选率 (tok=10, cand=5) */
#define NOMINMAX
#include <windows.h>
#include "llama.h"
#include <string>
#include <vector>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <sstream>

static std::string g_model_path = "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf";
static int g_n_ctx = 128, g_n_seq_max = 12, g_n_threads = 7;

static llama_model *g_model=nullptr; static llama_context *g_ctx=nullptr;
static const llama_vocab *g_vocab=nullptr;

static void log_msg(const char*f,...){va_list a;va_start(a,f);vprintf(f,a);va_end(a);printf("\n");fflush(stdout);}
static std::vector<llama_token> tokenize(const char*t){std::vector<llama_token> toks(128);
  int n=llama_tokenize(g_vocab,t,(int)strlen(t),toks.data(),(int)toks.size(),true,true);
  if(n<0){toks.resize(-n);n=llama_tokenize(g_vocab,t,(int)strlen(t),toks.data(),(int)toks.size(),true,true);}
  toks.resize(std::max(0,n));return toks;}
static double ce(float*l,int vs,int tid){float m=-1e30f;for(int k=0;k<vs;k++)if(l[k]>m)m=l[k];
  double se=0;for(int k=0;k<vs;k++)se+=exp((double)(l[k]-m));return-((double)(l[tid]-m)-log(se));}

struct S{std::string c,w,code;int pos,tot;std::vector<std::string> cands;};

int main(){
    log_msg("=== Train Corpus Accuracy: tok=10 cand=5 ===");
    llama_backend_init();
    auto mp=llama_model_default_params();mp.use_mmap=1;
    g_model=llama_model_load_from_file(g_model_path.c_str(),mp);
    if(!g_model){log_msg("ERROR model");return 1;}
    g_vocab=llama_model_get_vocab(g_model);
    auto cp=llama_context_default_params();
    cp.n_ctx=g_n_ctx;cp.n_threads=g_n_threads;cp.n_threads_batch=g_n_threads;cp.n_seq_max=g_n_seq_max;
    g_ctx=llama_new_context_with_model(g_model,cp);
    if(!g_ctx){log_msg("ERROR ctx");return 1;}
    {llama_memory_clear(llama_get_memory(g_ctx),false);llama_token t[4];
     int n=llama_tokenize(g_vocab,"\n",1,t,4,true,true);
     if(n>0){auto b=llama_batch_get_one(t,n);llama_decode(g_ctx,b);}}

    std::vector<S> ss;std::ifstream f("train_samples.tsv");std::string l;int skip=0;
    while(std::getline(f,l)){std::stringstream ls(l);S s;std::string ps,ts,cs;
      std::getline(ls,s.c,'\t');std::getline(ls,s.w,'\t');std::getline(ls,s.code,'\t');
      std::getline(ls,ps,'\t');std::getline(ls,cs,'\t');std::getline(ls,ts,'\t');
      s.pos=std::stoi(ps);s.tot=std::stoi(ts);
      std::stringstream cc(cs);std::string w;while(std::getline(cc,w,','))if(!w.empty())s.cands.push_back(w);
      ss.push_back(s);}
    log_msg("Loaded %zu training samples",ss.size());

    int64_t corr=0,tot=0;auto t0=std::chrono::high_resolution_clock::now();
    int vs=llama_n_vocab(g_vocab),MT=10,MC=5;

    for(int si=0;si<(int)ss.size();si++){auto&s=ss[si];
      auto ctx=tokenize(s.c.c_str());if(ctx.empty())continue;
      if((int)ctx.size()>MT)ctx.erase(ctx.begin(),ctx.end()-MT);
      int clen=(int)ctx.size();
      auto cids=tokenize(s.w.c_str());if(cids.empty())cids.push_back(0);
      std::vector<std::vector<llama_token>> oc;
      for(auto&w:s.cands){auto ids=tokenize(w.c_str());if(ids.empty())ids.push_back(0);oc.push_back(ids);}
      int W=s.tot,cp2=s.pos,nc=std::min(MC,W);
      if(W==1){corr++;tot++;continue;}
      if(cp2>=nc){tot++;continue;}
      std::vector<std::vector<llama_token>> cs;int oi=0;
      for(int p=0;p<nc;p++){if(p==cp2)cs.push_back(cids);else cs.push_back(oc[oi++]);}
      auto*mem=llama_get_memory(g_ctx);
      llama_memory_clear(mem,false);
      auto cb=llama_batch_init(clen,0,1);
      for(int j=0;j<clen;j++){cb.token[j]=ctx[j];cb.pos[j]=j;cb.n_seq_id[j]=1;cb.seq_id[j][0]=0;}
      cb.logits[clen-1]=1;cb.n_tokens=clen;
      std::vector<float> cxl;if(llama_decode(g_ctx,cb)!=0){llama_batch_free(cb);continue;}
      float*cll=llama_get_logits_ith(g_ctx,clen-1);if(!cll){llama_batch_free(cb);continue;}
      cxl.assign(cll,cll+vs);llama_batch_free(cb);
      std::vector<double> ce_sum(nc,0);
      for(int i=0;i<nc;i++)ce_sum[i]=ce(cxl.data(),vs,cs[i][0]);
      std::vector<int> i2,i3;
      for(int i=0;i<nc;i++){if(cs[i].size()>=2)i2.push_back(i);if(cs[i].size()>=3)i3.push_back(i);}
      int M=(int)i2.size(),K=(int)i3.size();std::vector<int> s2s(nc,-1);
      if(M>0){for(int s2=0;s2<M;s2++){llama_memory_seq_cp(mem,0,s2+1,0,-1);s2s[i2[s2]]=s2+1;}
        auto b2=llama_batch_init(M,0,M);
        for(int s2=0;s2<M;s2++){int ci=i2[s2];b2.token[s2]=cs[ci][0];b2.pos[s2]=clen;
          b2.n_seq_id[s2]=1;b2.seq_id[s2][0]=s2+1;b2.logits[s2]=1;}
        b2.n_tokens=M;
        if(llama_decode(g_ctx,b2)==0){for(int s2=0;s2<M;s2++){int ci=i2[s2];
          float*l=llama_get_logits_ith(g_ctx,s2);if(l)ce_sum[ci]+=ce(l,vs,cs[ci][1]);else ce_sum[ci]=-1e10;}}
        else{for(int ci:i2)ce_sum[ci]=-1e10;}llama_batch_free(b2);}
      if(K>0){auto b3=llama_batch_init(K,0,K);
        for(int s3=0;s3<K;s3++){int ci=i3[s3];b3.token[s3]=cs[ci][1];b3.pos[s3]=clen+1;
          b3.n_seq_id[s3]=1;b3.seq_id[s3][0]=s2s[ci];b3.logits[s3]=1;}
        b3.n_tokens=K;
        if(llama_decode(g_ctx,b3)==0){for(int s3=0;s3<K;s3++){int ci=i3[s3];
          float*l=llama_get_logits_ith(g_ctx,s3);if(l)ce_sum[ci]+=ce(l,vs,cs[ci][2]);else ce_sum[ci]=-1e10;}}
        else{for(int ci:i3)ce_sum[ci]=-1e10;}llama_batch_free(b3);}
      int best=0;for(int i=1;i<nc;i++)if(ce_sum[i]<ce_sum[best])best=i;
      tot++;if(best==cp2)corr++;
      if((si+1)%500==0){auto tn=std::chrono::high_resolution_clock::now();
        double ela=std::chrono::duration<double>(tn-t0).count();
        log_msg("  %d/%zu rate=%.1f/s acc=%.2f%%",si+1,ss.size(),(si+1)/ela,100.0*corr/tot);}
    }
    auto te=std::chrono::high_resolution_clock::now();
    double sec=std::chrono::duration<double>(te-t0).count();
    log_msg("Done. %.0fs corr=%lld/%lld acc=%.2f%%",sec,corr,tot,100.0*corr/tot);
    llama_free(g_ctx);llama_model_free(g_model);llama_backend_free();return 0;
}

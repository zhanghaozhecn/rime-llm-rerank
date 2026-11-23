// ngram.h — N-gram 组句器（万象 LTS `.gram` + 方案词典/essay 词频）
//
// 2026-11-23 整句模式第②段：研究库 `eval/tools/sentence_gen_gram.py` 的
// 生产移植（算法与参数逐项同构，便于离线对拍）。流程：
//   code 串格（每个起点枚举读音 == code[i:j] 的词）→ 逐码位 beam（文本去重、
//   截断 beam 宽）→ 末尾取 top-k。边分：
//     log(max(wt,1e-6)) - log(1e8) + gram.Query(上文, 词, is_rear)
//
// 词表来源 = 本方案自己的词典（码）+ 同目录 essay.txt（词频，引擎编译词典的
// 预设词频源）；万象词库也可直接喂（权重在第 3 列）。
//
// `.gram` 格式：`Rime::Grammar/1.0` 单 trie（44B 头 + Darts 双数组）与
// `Rime::DartsGrammar/3` 分区格式（研究库 eval/lib/wxgram.py 的 C++ 复刻）。
#ifndef RIME_LLM_NGRAM_H_
#define RIME_LLM_NGRAM_H_

#include <string>
#include <vector>

namespace rime_llm {
namespace ngram {

// 组句参数（默认值 = 研究脚本 sentence_gen_gram.py 的默认参数）
struct Params {
  int beam = 64;                            // 每码位保留状态数
  int topk = 5;                             // 输出句数
  int ctx_tail = 10;                        // 句前上文尾部字数
  int max_len = 6;                          // gram 查询窗口（collocation_max_length）
  int min_len = 2;                          // collocation_min_length
  double collocation_penalty = -14.0;
  double non_collocation_penalty = -6.0;
  double weak_collocation_penalty = -100.0;
  double rear_penalty = -18.0;
  double min_weight = 10.0;                 // 格的边词频下限
  int max_edges = 0;                        // 每个码位最多取多少条边（按词频降序；0=不限）
};

// 一个句子候选：text = 整句文本；words = 分词（word + 该词结束的 code 偏移）
struct Sentence {
  std::string text;
  struct Word {
    std::string word;
    int code_end = 0;   // 该词覆盖到 code[0..code_end) 结束
  };
  std::vector<Word> words;
  double score = 0.0;
};

class Engine {
 public:
  Engine();
  ~Engine();
  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;

  // gram_path 为空 = 只用词频（无 ngram）；dict_dir + dict_files = 词典；
  // essay_path 可空（词频回退 1.0）；cache_path 非空时优先 mmap 预构建索引，
  // 缺失/失效则解析词典并在构建后写回（见 ngram.cpp 的 CacheHeader 布局）。
  // dict_files 里的名字可带/不带 .dict.yaml。
  bool Load(const std::string& gram_path,
            const std::string& dict_dir,
            const std::vector<std::string>& dict_files,
            const std::string& essay_path,
            const std::string& cache_path = std::string());

  bool ready() const;
  const std::string& error() const;
  std::string status() const;   // 一行诊断（路径/词条数/gram 版本）

  // 线程安全：内部互斥（同进程可能多会话调用）。
  std::vector<Sentence> Generate(const std::string& code,
                                 const std::string& context,
                                 const Params& params);

 private:
  struct Impl;
  Impl* impl_;
};

// 词典读音归一：去声调（ā→a…ü→v）、去空格/撇号、小写。
std::string NormalizeReading(const std::string& code);

}  // namespace ngram
}  // namespace rime_llm

#endif  // RIME_LLM_NGRAM_H_

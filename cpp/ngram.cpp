// ngram.cpp — N-gram 组句器实现（研究库 sentence_gen_gram.py 的 C++ 移植）
//
// 三块：
//   ① Gram：万象 LTS `.gram`（Rime::Grammar/1.0 单 trie / DartsGrammar/3
//      分区）mmap 读取 + `Octagram::Query` 复刻（与 eval/lib/wxgram.py 逐行同构）。
//   ② Lexicon：词典（码 + 词频）。支持两种来源：
//        · 现成词典 yaml（万象 zi/jichu/... 带词频列；方案词典无词频列则
//          回退 essay.txt 预设词频）
//        · 预构建缓存 `ngram_lex.bin`（本文件自定义布局，mmap 直读；安装器
//          或首次加载时生成——1.7M 词条解析要 ~6s，mmap 只需 ~50ms）
//   ③ Beam：码串格 + 逐码位 beam（文本去重、截断），末位取 top-k。
#include "ngram.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace rime_llm {
namespace ngram {
namespace {

constexpr double kLogScale = 18.420680743952367;  // log(1e8)，librime 词典权重归一
constexpr size_t kMaxResults = 8;                 // Octagram lookup 上限
constexpr double kValueScale = 10000.0;
constexpr char kCacheMagic[8] = {'R', 'L', 'N', 'X', '1', '\0', '\0', '\0'};

// ── UTF-8 ──────────────────────────────────────────────────────────────
std::vector<uint32_t> Utf8ToCodepoints(const std::string& s) {
  std::vector<uint32_t> out;
  size_t i = 0;
  while (i < s.size()) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    uint32_t cp = 0;
    size_t len = 0;
    if (c < 0x80) {
      cp = c;
      len = 1;
    } else if ((c & 0xE0) == 0xC0) {
      cp = c & 0x1F;
      len = 2;
    } else if ((c & 0xF0) == 0xE0) {
      cp = c & 0x0F;
      len = 3;
    } else if ((c & 0xF8) == 0xF0) {
      cp = c & 0x07;
      len = 4;
    } else {
      ++i;
      continue;
    }
    if (i + len > s.size()) break;
    bool ok = true;
    for (size_t k = 1; k < len; ++k) {
      unsigned char cc = static_cast<unsigned char>(s[i + k]);
      if ((cc & 0xC0) != 0x80) {
        ok = false;
        break;
      }
      cp = (cp << 6) | (cc & 0x3F);
    }
    if (!ok) {
      ++i;
      continue;
    }
    out.push_back(cp);
    i += len;
  }
  return out;
}

std::string CodepointsToUtf8(const std::vector<uint32_t>& cps, size_t begin,
                             size_t end) {
  std::string out;
  if (begin >= end || begin >= cps.size()) return out;
  end = std::min(end, cps.size());
  out.reserve((end - begin) * 3);
  for (size_t i = begin; i < end; ++i) {
    uint32_t cp = cps[i];
    if (cp < 0x80) {
      out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
      out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
      out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
      out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
  }
  return out;
}

// gram_encoding：UTF-8 → librime 压缩编码（wxgram.py encode 的逐行复刻）
void EncodeAppend(uint32_t u, std::vector<uint8_t>* out) {
  if (u < 0x80) {
    out->push_back(static_cast<uint8_t>(u == 0 ? 0xE0 : u));
    return;
  }
  if (u >= 0x4000 && u < 0xA000) {
    uint32_t hi = u >> 8;
    uint32_t lo = u & 0xFF;
    if (lo == 0) {
      out->push_back(0xE1);
      out->push_back(static_cast<uint8_t>(hi + 0x40));
    } else {
      out->push_back(static_cast<uint8_t>(hi + 0x40));
      out->push_back(static_cast<uint8_t>(lo));
    }
    return;
  }
  int bits = 32;
  uint32_t v = u;
  while (bits > 0 && (v & 0xFE000000) == 0) {
    bits -= 7;
    v = (v << 7) & 0xFFFFFFFF;
  }
  int n = (bits + 6) / 7;
  out->push_back(static_cast<uint8_t>(0xE0 | n));
  while (n > 0) {
    --n;
    out->push_back(static_cast<uint8_t>(((v >> 25) & 0x7F) | 0x80));
    v = (v << 7) & 0xFFFFFFFF;
  }
}

std::vector<uint8_t> EncodeCodepoints(const std::vector<uint32_t>& cps,
                                      size_t begin, size_t end) {
  std::vector<uint8_t> out;
  if (begin >= end || begin >= cps.size()) return out;
  end = std::min(end, cps.size());
  out.reserve((end - begin) * 2);
  for (size_t i = begin; i < end; ++i) EncodeAppend(cps[i], &out);
  return out;
}

size_t Advance(const std::vector<uint8_t>& enc, size_t pos) {
  if (pos >= enc.size()) return pos + 1;
  uint8_t b = enc[pos];
  if (!(b & 0x80)) return pos + 1;
  if ((b & 0xF0) == 0xE0) return pos + (b & 0x0F) + 1;
  return pos + 2;
}

size_t UnicodeLength(const std::vector<uint8_t>& enc, size_t length) {
  size_t n = 0;
  size_t p = 0;
  length = std::min(length, enc.size());
  while (p < length) {
    p = Advance(enc, p);
    ++n;
  }
  return n;
}

// ── 只读 mmap ──────────────────────────────────────────────────────────
class MappedFile {
 public:
  MappedFile() = default;
  ~MappedFile() { Close(); }
  MappedFile(const MappedFile&) = delete;
  MappedFile& operator=(const MappedFile&) = delete;

  bool Open(const std::string& path) {
    Close();
    HANDLE f = CreateFileA(
        path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(f, &sz) || sz.QuadPart <= 0) {
      CloseHandle(f);
      return false;
    }
    HANDLE m = CreateFileMappingA(f, nullptr, PAGE_READONLY, 0, 0, nullptr);
    if (!m) {
      CloseHandle(f);
      return false;
    }
    void* p = MapViewOfFile(m, FILE_MAP_READ, 0, 0, 0);
    if (!p) {
      CloseHandle(m);
      CloseHandle(f);
      return false;
    }
    file_ = f;
    map_ = m;
    data_ = static_cast<const uint8_t*>(p);
    size_ = static_cast<size_t>(sz.QuadPart);
    return true;
  }

  void Close() {
    if (data_) {
      UnmapViewOfFile(data_);
      data_ = nullptr;
    }
    if (map_) {
      CloseHandle(map_);
      map_ = nullptr;
    }
    if (file_ != INVALID_HANDLE_VALUE) {
      CloseHandle(file_);
      file_ = INVALID_HANDLE_VALUE;
    }
    size_ = 0;
  }

  const uint8_t* data() const { return data_; }
  size_t size() const { return size_; }

 private:
  HANDLE file_ = INVALID_HANDLE_VALUE;
  HANDLE map_ = nullptr;
  const uint8_t* data_ = nullptr;
  size_t size_ = 0;
};

uint32_t LoadU32(const uint8_t* p) {
  uint32_t v = 0;
  std::memcpy(&v, p, sizeof(v));  // 小端 x64
  return v;
}

// ── Gram（`.gram` 读取 + Octagram::Query）──────────────────────────────
class Gram {
 public:
  struct Section {
    std::string name;
    size_t image = 0;
    int64_t const_value = -1;
    size_t units = 0;
  };

  bool Open(const std::string& path, std::string* err) {
    if (!file_.Open(path)) {
      if (err) *err = "open gram failed: " + path;
      return false;
    }
    if (file_.size() < 44) {
      if (err) *err = "gram too small";
      return false;
    }
    const uint8_t* d = file_.data();
    std::string fmt(reinterpret_cast<const char*>(d), 32);
    fmt = fmt.c_str();  // 截到首个 NUL
    if (fmt.compare(0, 16, "Rime::DartsGramm") == 0) return LoadV3(err);
    if (fmt.compare(0, 13, "Rime::Grammar") == 0) return LoadV1(err);
    if (err) *err = "unknown gram format: " + fmt;
    return false;
  }

  bool ready() const { return !sections_.empty(); }
  const std::string& version() const { return version_; }
  size_t units() const { return sections_.empty() ? 0 : sections_.back().units; }

  // Octagram::Query（已编码版）：上下文 suffix × 词前缀，取最大（log 频次 + 罚分）
  double Query(const std::vector<uint8_t>& ctx_enc, size_t ctx_len,
               const std::vector<uint8_t>& word_enc, size_t word_cps,
               bool is_rear, const Params& p) const {
    if (ctx_len == 0 || ctx_enc.empty()) return p.non_collocation_penalty;
    double result = p.non_collocation_penalty;
    size_t pos = 0;
    size_t context_len = ctx_len;
    while (context_len > 0) {
      std::vector<std::pair<size_t, int64_t>> matches;
      Lookup(ctx_enc, pos, word_enc, &matches);
      for (size_t k = 0; k < matches.size(); ++k) {
        size_t enc_len = matches[k].first;
        double val = static_cast<double>(matches[k].second);
        size_t match_len = UnicodeLength(word_enc, enc_len);
        size_t colloc_len = context_len + match_len;
        bool whole = (pos == 0 && enc_len == word_enc.size());
        double score =
            val / kValueScale +
            ((colloc_len >= static_cast<size_t>(p.min_len) || whole)
                 ? p.collocation_penalty
                 : p.weak_collocation_penalty);
        if (score > result) result = score;
      }
      pos = Advance(ctx_enc, pos);
      --context_len;
    }
    size_t n = static_cast<size_t>(std::max(0, std::min(8, p.max_len - 1)));
    if (is_rear && word_cps <= n) {
      std::vector<uint32_t> dollar = {'$'};
      std::vector<uint8_t> dollar_enc = EncodeCodepoints(dollar, 0, 1);
      std::vector<std::pair<size_t, int64_t>> m;
      Lookup(word_enc, 0, dollar_enc, &m);
      if (!m.empty()) {
        double score =
            static_cast<double>(m[0].second) / kValueScale + p.rear_penalty;
        if (score > result) result = score;
      }
    }
    return result;
  }

 private:
  bool LoadV3(std::string* err) {
    const uint8_t* d = file_.data();
    uint64_t count = 0;
    uint64_t names_bytes = 0;
    std::memcpy(&count, d + 32, 8);
    std::memcpy(&names_bytes, d + 40, 8);
    if (count == 0 || count > 4096) {
      if (err) *err = "v3 section count invalid";
      return false;
    }
    size_t table_end = 48 + static_cast<size_t>(count) * 24;
    size_t padded =
        (static_cast<size_t>(names_bytes) + 3) & ~static_cast<size_t>(3);
    if (table_end + padded > file_.size()) {
      if (err) *err = "v3 truncated";
      return false;
    }
    const uint8_t* names = d + table_end;
    size_t off = table_end + padded;
    size_t pos = 0;
    for (uint64_t i = 0; i < count; ++i) {
      const uint8_t* sec = d + 48 + i * 24;
      uint64_t array_bytes = 0;
      int64_t const_val = 0;
      uint64_t name_bytes = 0;
      std::memcpy(&array_bytes, sec, 8);
      std::memcpy(&const_val, sec + 8, 8);
      std::memcpy(&name_bytes, sec + 16, 8);
      if (pos + name_bytes > names_bytes) {
        if (err) *err = "v3 section name overflow";
        return false;
      }
      Section s;
      s.name.assign(reinterpret_cast<const char*>(names + pos),
                    static_cast<size_t>(name_bytes));
      pos += static_cast<size_t>(name_bytes);
      if (off + array_bytes > file_.size()) {
        if (err) *err = "v3 section image truncated: " + s.name;
        return false;
      }
      s.image = off;
      s.const_value = const_val;
      s.units = static_cast<size_t>(array_bytes / 4);
      off += static_cast<size_t>(array_bytes);
      sections_.push_back(s);
    }
    version_ = "v3";
    return true;
  }

  bool LoadV1(std::string* err) {
    const uint8_t* d = file_.data();
    uint32_t units = 0;
    int32_t rel = 0;
    std::memcpy(&units, d + 36, 4);
    std::memcpy(&rel, d + 40, 4);
    size_t image = 40 + static_cast<size_t>(rel);  // OffsetPtr 相对自身字段
    if (image >= file_.size()) {
      if (err) *err = "v1 image offset out of range";
      return false;
    }
    size_t avail = (file_.size() - image) / 4;
    Section s;
    s.name = "default";
    s.image = image;
    s.const_value = -1;
    s.units = std::min<size_t>(units, avail);  // ShrinkToFit 截尾容错
    sections_.push_back(s);
    version_ = "v1";
    return true;
  }

  uint32_t Unit(size_t image, size_t pos) const {
    return LoadU32(file_.data() + image + pos * 4);
  }

  static size_t OffsetOf(uint32_t u) {
    return static_cast<size_t>(u >> 10) << ((u & 0x200) >> 6);
  }

  static uint32_t LabelOf(uint32_t u) {
    return (u & 0x80000000u) | (u & 0xFFu);
  }

  long Traverse(size_t image, const std::vector<uint8_t>& key) const {
    size_t node = 0;
    uint32_t unit = Unit(image, node);
    for (size_t i = 0; i < key.size(); ++i) {
      node ^= OffsetOf(unit) ^ key[i];
      if (image + node * 4 + 4 > file_.size()) return -1;
      unit = Unit(image, node);
      if (LabelOf(unit) != key[i]) return -1;
    }
    return static_cast<long>(node);
  }

  void CommonPrefix(size_t image, const std::vector<uint8_t>& key, size_t node,
                    std::vector<std::pair<size_t, int64_t>>* out) const {
    uint32_t unit = Unit(image, node);
    node ^= OffsetOf(unit);
    for (size_t i = 0; i < key.size(); ++i) {
      node ^= key[i];
      if (image + node * 4 + 4 > file_.size()) break;
      unit = Unit(image, node);
      if (LabelOf(unit) != key[i]) break;
      node ^= OffsetOf(unit);
      if ((unit >> 8) & 1) {
        // 取值前必须再验边界（OffsetOf 跳转后）；Python mmap 越界会抛错，
        // C++ 不检查就是读到相邻内存 → 结果被污染甚至崩溃。
        if (image + node * 4 + 4 > file_.size()) break;
        out->push_back(std::make_pair(
            i + 1, static_cast<int64_t>(Unit(image, node) & 0x7FFFFFFFu)));
        if (out->size() >= kMaxResults) break;
      }
    }
  }

  void LookupSection(const Section& s, const std::vector<uint8_t>& ctx_enc,
                     size_t ctx_pos, const std::vector<uint8_t>& word_enc,
                     std::vector<std::pair<size_t, int64_t>>* out) const {
    if (ctx_pos > ctx_enc.size()) return;
    std::vector<uint8_t> suffix(ctx_enc.begin() + ctx_pos, ctx_enc.end());
    long node = Traverse(s.image, suffix);
    if (node < 0) return;
    std::vector<std::pair<size_t, int64_t>> matches;
    CommonPrefix(s.image, word_enc, static_cast<size_t>(node), &matches);
    if (s.const_value >= 0) {
      for (size_t i = 0; i < matches.size(); ++i)
        out->push_back(std::make_pair(matches[i].first, s.const_value));
    } else {
      out->insert(out->end(), matches.begin(), matches.end());
    }
  }

  // 全部分区合并（同匹配长度时后面的分区覆盖），最多 kMaxResults 条
  void Lookup(const std::vector<uint8_t>& ctx_enc, size_t ctx_pos,
              const std::vector<uint8_t>& word_enc,
              std::vector<std::pair<size_t, int64_t>>* out) const {
    out->clear();
    if (word_enc.empty()) return;
    std::vector<std::pair<size_t, int64_t>> merged;
    for (size_t i = 0; i < sections_.size(); ++i) {
      std::vector<std::pair<size_t, int64_t>> sec;
      LookupSection(sections_[i], ctx_enc, ctx_pos, word_enc, &sec);
      for (size_t k = 0; k < sec.size(); ++k) {
        size_t ln = sec[k].first;
        size_t pos = 0;
        while (pos < merged.size() && merged[pos].first < ln) ++pos;
        if (pos < merged.size() && merged[pos].first == ln) {
          merged[pos] = sec[k];
        } else if (merged.size() < kMaxResults) {
          merged.insert(merged.begin() + pos, sec[k]);
        }
      }
    }
    out->swap(merged);
  }

  MappedFile file_;
  std::vector<Section> sections_;
  std::string version_;
};

// ── 词表：二进制布局（内存构建与 mmap 缓存共用同一份结构）──────────────
struct CacheHeader {
  char magic[8];
  uint32_t version;
  uint32_t reserved;
  uint64_t code_count;
  uint64_t rec_count;
  uint64_t codes_off;
  uint64_t recs_off;
  uint64_t code_pool_off;
  uint64_t code_pool_size;
  uint64_t word_pool_off;
  uint64_t word_pool_size;
};

struct CodeMeta {   // 16B
  uint32_t off;     // code_pool 偏移
  uint32_t len;
  uint32_t first;   // recs 索引
  uint32_t count;
};

struct LexRec {     // 16B
  uint32_t word_off;
  uint32_t word_len;
  float weight;
  uint32_t reserved;
};

bool ParseDouble(const std::string& s, double* out) {
  if (s.empty()) return false;
  char* end = nullptr;
  double v = std::strtod(s.c_str(), &end);
  if (end == s.c_str() || *end != '\0') return false;
  *out = v;
  return true;
}

std::string Trim(const std::string& s) {
  size_t b = s.find_first_not_of(" \t\r\n");
  if (b == std::string::npos) return std::string();
  size_t e = s.find_last_not_of(" \t\r\n");
  return s.substr(b, e - b + 1);
}

std::unordered_map<std::string, double> LoadEssay(const std::string& path) {
  std::unordered_map<std::string, double> out;
  FILE* f = nullptr;
  if (fopen_s(&f, path.c_str(), "rb") != 0 || !f) return out;
  char buf[4096];
  while (fgets(buf, sizeof(buf), f)) {
    std::string line(buf);
    while (!line.empty() && (line.back() == '\n' || line.back() == '\r'))
      line.pop_back();
    if (line.empty() || line[0] == '#') continue;
    size_t tab = line.find('\t');
    if (tab == std::string::npos) continue;
    std::string word = line.substr(0, tab);
    double freq = 0.0;
    if (!ParseDouble(Trim(line.substr(tab + 1)), &freq)) continue;
    if (word.empty()) continue;
    auto it = out.find(word);
    if (it == out.end() || freq > it->second) out[word] = freq;
  }
  fclose(f);
  return out;
}

std::string JoinPath(const std::string& dir, const std::string& name) {
  if (dir.empty()) return name;
  char last = dir.back();
  if (last == '\\' || last == '/') return dir + name;
  return dir + "\\" + name;
}

bool EndsWithDictYaml(const std::string& name) {
  static const char* kSuffix = ".dict.yaml";
  const size_t n = std::strlen(kSuffix);
  return name.size() >= n && name.compare(name.size() - n, n, kSuffix) == 0;
}

std::vector<std::string> HeaderImports(const std::vector<std::string>& header) {
  std::vector<std::string> out;
  bool in_list = false;
  for (size_t i = 0; i < header.size(); ++i) {
    std::string t = Trim(header[i]);
    if (!in_list) {
      if (t.compare(0, 12, "import_tables") == 0) in_list = true;
      continue;
    }
    if (!t.empty() && t[0] == '-') {
      std::string name = Trim(t.substr(1));
      if (!name.empty()) out.push_back(name);
    } else if (!t.empty()) {
      in_list = false;
    }
  }
  return out;
}

std::string NormalizePathKey(const std::string& path) {
  std::string key = path;
  for (size_t i = 0; i < key.size(); ++i) {
    if (key[i] == '/') {
      key[i] = '\\';
    } else if (key[i] >= 'A' && key[i] <= 'Z') {
      key[i] = static_cast<char>(key[i] - 'A' + 'a');
    }
  }
  return key;
}

struct RawEntry {
  std::string code;
  std::string word;
  double weight = 1.0;
};

}  // namespace

std::string NormalizeReading(const std::string& code) {
  // 声调 → 无调字母、ü → v（万象 algebra xlit），去空格/撇号、转小写
  static const struct {
    const char* from;
    const char* to;
  } kMap[] = {
      {"ā", "a"}, {"á", "a"}, {"ǎ", "a"}, {"à", "a"}, {"ē", "e"}, {"é", "e"},
      {"ě", "e"}, {"è", "e"}, {"ī", "i"}, {"í", "i"}, {"ǐ", "i"}, {"ì", "i"},
      {"ō", "o"}, {"ó", "o"}, {"ǒ", "o"}, {"ò", "o"}, {"ū", "u"}, {"ú", "u"},
      {"ǔ", "u"}, {"ù", "u"}, {"ü", "v"}, {"ǖ", "v"}, {"ǘ", "v"}, {"ǚ", "v"},
      {"ǜ", "v"}, {"ń", "n"}, {"ň", "n"}, {"ǹ", "n"}, {"ḿ", "m"},
  };
  std::string s = code;
  for (size_t i = 0; i < sizeof(kMap) / sizeof(kMap[0]); ++i) {
    const std::string from = kMap[i].from;
    const std::string to = kMap[i].to;
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos) {
      s.replace(pos, from.size(), to);
      pos += to.size();
    }
  }
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); ++i) {
    char c = s[i];
    if (c == ' ' || c == '\'' || c == '\t') continue;
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    out.push_back(c);
  }
  return out;
}

struct Engine::Impl {
  Gram gram;
  bool have_gram = false;
  std::string error;
  std::string status;
  std::string gram_path;
  std::string dict_dir;
  std::vector<std::string> dict_files;
  std::string essay_path;
  std::string cache_path;
  std::mutex mu;

  // 词表：内存向量（构建态）或 mmap 缓存（只读态），访问一律走下面的
  // 访问器——两种来源共用同一份二进制布局。
  std::vector<CodeMeta> codes;
  std::vector<LexRec> recs;
  std::vector<char> code_pool;
  std::vector<char> word_pool;
  std::unordered_map<std::string, double> essay_cache;
  MappedFile cache;
  bool from_cache = false;

  size_t code_count() const {
    return from_cache ? cache_code_count_ : codes.size();
  }
  size_t rec_count() const {
    return from_cache ? cache_rec_count_ : recs.size();
  }
  const CodeMeta* codes_data() const {
    return from_cache ? cache_codes_ : codes.data();
  }
  const LexRec* recs_data() const {
    return from_cache ? cache_recs_ : recs.data();
  }
  const char* code_pool_data() const {
    return from_cache ? cache_code_pool_ : code_pool.data();
  }
  const char* word_pool_data() const {
    return from_cache ? cache_word_pool_ : word_pool.data();
  }

  size_t cache_code_count_ = 0;
  size_t cache_rec_count_ = 0;
  const CodeMeta* cache_codes_ = nullptr;
  const LexRec* cache_recs_ = nullptr;
  const char* cache_code_pool_ = nullptr;
  const char* cache_word_pool_ = nullptr;

  bool LoadCache();
  bool BuildFromDicts();
  bool WriteCache() const;
  bool FindCode(const std::string& code, uint32_t* first,
                uint32_t* count) const;

 private:
  bool ParseDictFile(const std::string& filename,
                     std::unordered_map<std::string, int>* visited,
                     std::vector<RawEntry>* out);
};

bool Engine::Impl::LoadCache() {
  if (cache_path.empty() || !cache.Open(cache_path)) return false;
  const uint8_t* d = cache.data();
  if (cache.size() < sizeof(CacheHeader)) return false;
  CacheHeader h;
  std::memcpy(&h, d, sizeof(h));
  if (std::memcmp(h.magic, kCacheMagic, 8) != 0 || h.version != 1) {
    cache.Close();
    return false;
  }
  const uint64_t need = std::max<uint64_t>(
      std::max(h.codes_off + h.code_count * sizeof(CodeMeta),
               h.recs_off + h.rec_count * sizeof(LexRec)),
      std::max(h.code_pool_off + h.code_pool_size,
               h.word_pool_off + h.word_pool_size));
  if (need > cache.size()) {
    cache.Close();
    return false;
  }
  cache_code_count_ = static_cast<size_t>(h.code_count);
  cache_rec_count_ = static_cast<size_t>(h.rec_count);
  cache_codes_ = reinterpret_cast<const CodeMeta*>(d + h.codes_off);
  cache_recs_ = reinterpret_cast<const LexRec*>(d + h.recs_off);
  cache_code_pool_ = reinterpret_cast<const char*>(d + h.code_pool_off);
  cache_word_pool_ = reinterpret_cast<const char*>(d + h.word_pool_off);
  from_cache = true;
  return true;
}

bool Engine::Impl::ParseDictFile(
    const std::string& filename,
    std::unordered_map<std::string, int>* visited,
    std::vector<RawEntry>* out) {
  const std::string path = JoinPath(dict_dir, filename);
  const std::string key = NormalizePathKey(path);
  if (visited->count(key)) return true;
  (*visited)[key] = 1;

  char buf[8192];
  std::vector<std::string> header;
  bool header_done = false;
  FILE* f = nullptr;
  if (fopen_s(&f, path.c_str(), "rb") != 0 || !f) {
    error = "open dict failed: " + path;
    return false;
  }
  while (fgets(buf, sizeof(buf), f)) {
    std::string line(buf);
    while (!line.empty() && (line.back() == '\n' || line.back() == '\r'))
      line.pop_back();
    if (Trim(line) == "...") {
      header_done = true;
      break;
    }
    header.push_back(line);
  }
  fclose(f);
  if (!header_done) {
    error = "dict header not terminated: " + path;
    return false;
  }

  // 导入表先加载（Rime 语义：先 import 再自身）
  const std::vector<std::string> imports = HeaderImports(header);
  for (size_t i = 0; i < imports.size(); ++i) {
    std::string name = imports[i];
    if (!EndsWithDictYaml(name)) name += ".dict.yaml";
    if (!ParseDictFile(name, visited, out)) return false;
  }

  if (fopen_s(&f, path.c_str(), "rb") != 0 || !f) {
    error = "reopen dict failed: " + path;
    return false;
  }
  bool in_body = false;
  while (fgets(buf, sizeof(buf), f)) {
    std::string line(buf);
    while (!line.empty() && (line.back() == '\n' || line.back() == '\r'))
      line.pop_back();
    if (!in_body) {
      if (Trim(line) == "...") in_body = true;
      continue;
    }
    if (line.empty() || line[0] == '#') continue;
    const size_t t1 = line.find('\t');
    if (t1 == std::string::npos) continue;
    const size_t t2 = line.find('\t', t1 + 1);
    const std::string word = line.substr(0, t1);
    const std::string code = NormalizeReading(
        line.substr(t1 + 1, t2 == std::string::npos ? std::string::npos
                                                    : t2 - t1 - 1));
    if (word.empty() || code.empty()) continue;
    bool ascii_alpha = true;
    for (size_t i = 0; i < code.size(); ++i) {
      const char c = code[i];
      if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) {
        ascii_alpha = false;
        break;
      }
    }
    if (!ascii_alpha) continue;
    double wt = 1.0;
    bool have_wt = false;
    if (t2 != std::string::npos) {
      const size_t t3 = line.find('\t', t2 + 1);
      const std::string third =
          line.substr(t2 + 1, t3 == std::string::npos ? std::string::npos
                                                     : t3 - t2 - 1);
      have_wt = ParseDouble(Trim(third), &wt);
    }
    if (!have_wt) {
      // 方案词典无频次列：用 essay.txt 预设词频（引擎编译词典同源）
      auto it = essay_cache.find(word);
      wt = (it == essay_cache.end()) ? 1.0 : std::max(1.0, it->second);
    }
    if (wt <= 0.0) wt = 1.0;
    RawEntry e;
    e.code = code;
    e.word = word;
    e.weight = wt;
    out->push_back(std::move(e));
  }
  fclose(f);
  return true;
}

bool Engine::Impl::BuildFromDicts() {
  std::vector<RawEntry> raw;
  std::unordered_map<std::string, int> visited;
  for (size_t i = 0; i < dict_files.size(); ++i) {
    std::string name = dict_files[i];
    if (!EndsWithDictYaml(name)) name += ".dict.yaml";
    if (!ParseDictFile(name, &visited, &raw)) return false;
  }
  // 按码排序（stable：同码内保持文件顺序 = 研究脚本的插入序）
  std::stable_sort(raw.begin(), raw.end(), [](const RawEntry& a,
                                              const RawEntry& b) {
    return a.code < b.code;
  });

  codes.clear();
  recs.clear();
  code_pool.clear();
  word_pool.clear();
  codes.reserve(raw.size() / 4 + 1);
  recs.reserve(raw.size());
  code_pool.reserve(raw.size() * 4);
  word_pool.reserve(raw.size() * 4);

  size_t i = 0;
  std::vector<std::pair<size_t, double>> group;  // (raw 索引, 权重)
  std::unordered_map<std::string, size_t> seen;  // 词 → group 位置
  while (i < raw.size()) {
    const std::string& code = raw[i].code;
    size_t j = i;
    group.clear();
    seen.clear();
    while (j < raw.size() && raw[j].code == code) {
      auto it = seen.find(raw[j].word);
      if (it == seen.end()) {
        seen.emplace(raw[j].word, group.size());
        group.push_back(std::make_pair(j, raw[j].weight));
      } else if (raw[j].weight > group[it->second].second) {
        group[it->second] = std::make_pair(j, raw[j].weight);
      }
      ++j;
    }
    CodeMeta m;
    m.off = static_cast<uint32_t>(code_pool.size());
    m.len = static_cast<uint32_t>(code.size());
    m.first = static_cast<uint32_t>(recs.size());
    m.count = static_cast<uint32_t>(group.size());
    code_pool.insert(code_pool.end(), code.begin(), code.end());
    for (size_t g = 0; g < group.size(); ++g) {
      const RawEntry& e = raw[group[g].first];
      LexRec r;
      r.word_off = static_cast<uint32_t>(word_pool.size());
      r.word_len = static_cast<uint32_t>(e.word.size());
      r.weight = static_cast<float>(e.weight);
      r.reserved = 0;
      word_pool.insert(word_pool.end(), e.word.begin(), e.word.end());
      recs.push_back(r);
    }
    codes.push_back(m);
    i = j;
  }
  return true;
}

bool Engine::Impl::WriteCache() const {
  if (cache_path.empty()) return false;
  CacheHeader h;
  std::memset(&h, 0, sizeof(h));
  std::memcpy(h.magic, kCacheMagic, 8);
  h.version = 1;
  h.code_count = codes.size();
  h.rec_count = recs.size();
  h.codes_off = sizeof(CacheHeader);
  h.recs_off = (h.codes_off + codes.size() * sizeof(CodeMeta) + 7) & ~7ull;
  h.code_pool_off = (h.recs_off + recs.size() * sizeof(LexRec) + 7) & ~7ull;
  h.code_pool_size = code_pool.size();
  h.word_pool_off = (h.code_pool_off + code_pool.size() + 7) & ~7ull;
  h.word_pool_size = word_pool.size();

  FILE* f = nullptr;
  if (fopen_s(&f, cache_path.c_str(), "wb") != 0 || !f) return false;
  bool ok = fwrite(&h, sizeof(h), 1, f) == 1;
  if (ok) ok = fwrite(codes.data(), sizeof(CodeMeta), codes.size(), f) ==
              codes.size();
  if (ok) {
    const long pos = ftell(f);
    if (pos >= 0 && static_cast<uint64_t>(pos) < h.recs_off) {
      std::vector<char> pad(static_cast<size_t>(h.recs_off - pos), 0);
      ok = fwrite(pad.data(), 1, pad.size(), f) == pad.size();
    }
  }
  if (ok) ok = fwrite(recs.data(), sizeof(LexRec), recs.size(), f) ==
              recs.size();
  if (ok) {
    const long pos = ftell(f);
    if (pos >= 0 && static_cast<uint64_t>(pos) < h.code_pool_off) {
      std::vector<char> pad(static_cast<size_t>(h.code_pool_off - pos), 0);
      ok = fwrite(pad.data(), 1, pad.size(), f) == pad.size();
    }
  }
  if (ok && !code_pool.empty())
    ok = fwrite(code_pool.data(), 1, code_pool.size(), f) == code_pool.size();
  if (ok) {
    const long pos = ftell(f);
    if (pos >= 0 && static_cast<uint64_t>(pos) < h.word_pool_off) {
      std::vector<char> pad(static_cast<size_t>(h.word_pool_off - pos), 0);
      ok = fwrite(pad.data(), 1, pad.size(), f) == pad.size();
    }
  }
  if (ok && !word_pool.empty())
    ok = fwrite(word_pool.data(), 1, word_pool.size(), f) == word_pool.size();
  fclose(f);
  return ok;
}

bool Engine::Impl::FindCode(const std::string& code, uint32_t* first,
                            uint32_t* count) const {
  size_t lo = 0;
  size_t hi = code_count();
  const char* pool = code_pool_data();
  const CodeMeta* cs = codes_data();
  while (lo < hi) {
    const size_t mid = (lo + hi) / 2;
    const CodeMeta& m = cs[mid];
    const size_t n = std::min<size_t>(m.len, code.size());
    int cmp = std::memcmp(pool + m.off, code.data(), n);
    if (cmp == 0) {
      if (m.len < code.size()) {
        cmp = -1;
      } else if (m.len > code.size()) {
        cmp = 1;
      }
    }
    if (cmp < 0) {
      lo = mid + 1;
    } else if (cmp > 0) {
      hi = mid;
    } else {
      *first = m.first;
      *count = m.count;
      return true;
    }
  }
  return false;
}

Engine::Engine() : impl_(new Impl) {}
Engine::~Engine() { delete impl_; }

bool Engine::Load(const std::string& gram_path,
                  const std::string& dict_dir,
                  const std::vector<std::string>& dict_files,
                  const std::string& essay_path,
                  const std::string& cache_path) {
  std::lock_guard<std::mutex> lock(impl_->mu);
  impl_->error.clear();
  impl_->status.clear();
  impl_->gram_path = gram_path;
  impl_->dict_dir = dict_dir;
  impl_->dict_files = dict_files;
  impl_->essay_path = essay_path;
  impl_->cache_path = cache_path;
  impl_->from_cache = false;
  impl_->codes.clear();
  impl_->recs.clear();
  impl_->code_pool.clear();
  impl_->word_pool.clear();
  impl_->cache.Close();
  if (!gram_path.empty()) {
    std::string err;
    if (!impl_->gram.Open(gram_path, &err)) {
      impl_->error = err;
      return false;
    }
    impl_->have_gram = true;
  } else {
    impl_->have_gram = false;
  }

  bool cache_ok = impl_->LoadCache();
  if (!cache_ok) {
    impl_->essay_cache.clear();
    if (!essay_path.empty()) impl_->essay_cache = LoadEssay(essay_path);
    if (!impl_->BuildFromDicts()) return false;
    // 首次构建后落缓存（安装器若已预构建则不会走到这里）
    impl_->WriteCache();
  }
  char buf[768];
  _snprintf_s(buf, sizeof(buf), _TRUNCATE,
              "gram=%s(%s units=%zu) lex=%s entries=%zu codes=%zu essay=%zu",
              gram_path.empty() ? "-" : gram_path.c_str(),
              impl_->gram.version().c_str(), impl_->gram.units(),
              cache_ok ? "cache" : "yaml", impl_->rec_count(),
              impl_->code_count(), impl_->essay_cache.size());
  impl_->status = buf;
  return true;
}

bool Engine::ready() const { return impl_->rec_count() > 0; }

const std::string& Engine::error() const { return impl_->error; }

std::string Engine::status() const {
  std::lock_guard<std::mutex> lock(impl_->mu);
  return impl_->status;
}

std::vector<Sentence> Engine::Generate(const std::string& code,
                                       const std::string& context,
                                       const Params& p) {
  std::lock_guard<std::mutex> lock(impl_->mu);
  std::vector<Sentence> out;
  const int n = static_cast<int>(code.size());
  if (n <= 0 || impl_->rec_count() == 0) return out;

  const std::vector<uint32_t> ctx_cps = Utf8ToCodepoints(context);
  const size_t tail_n = static_cast<size_t>(std::max(0, p.ctx_tail));
  const size_t ctx_begin =
      ctx_cps.size() > tail_n ? ctx_cps.size() - tail_n : 0;
  const std::string prev_tail =
      CodepointsToUtf8(ctx_cps, ctx_begin, ctx_cps.size());

  const LexRec* recs = impl_->recs_data();
  const char* word_pool = impl_->word_pool_data();

  struct Node {
    double score = 0.0;
    int parent = -1;
    std::string text;
    std::string word;
    int code_j = 0;
  };
  std::vector<Node> nodes;
  nodes.reserve(4096);
  std::vector<std::vector<int>> states(static_cast<size_t>(n) + 1);
  nodes.push_back(Node());
  states[0].push_back(0);

  std::unordered_map<std::string, double> query_cache;
  std::unordered_map<std::string, std::vector<uint32_t>> word_cps_cache;
  const size_t gram_n =
      static_cast<size_t>(std::max(0, std::min(8, p.max_len - 1)));

  for (int i = 0; i < n; ++i) {
    if (states[i].empty()) continue;
    // 位内去重（同文本保最高分）+ 截断 beam（稳定排序，同分保插入序）
    // 插入序与 Python dict 一致：同文本首次出现的位置不变、只更新为更高分项。
    std::unordered_map<std::string, size_t> pos;
    std::vector<int> kept;
    pos.reserve(states[i].size() * 2);
    kept.reserve(states[i].size());
    for (size_t k = 0; k < states[i].size(); ++k) {
      const int idx = states[i][k];
      auto it = pos.find(nodes[idx].text);
      if (it == pos.end()) {
        pos.emplace(nodes[idx].text, kept.size());
        kept.push_back(idx);
      } else if (nodes[idx].score > nodes[kept[it->second]].score) {
        kept[it->second] = idx;
      }
    }
    std::stable_sort(kept.begin(), kept.end(), [&](int a, int b) {
      return nodes[a].score > nodes[b].score;
    });
    if (static_cast<int>(kept.size()) > p.beam) kept.resize(p.beam);
    states[i].swap(kept);

    for (size_t s = 0; s < states[i].size(); ++s) {
      const int cur_idx = states[i][s];
      // 注意：nodes.push_back 会让引用失效——当前节点必须按值取用
      const double cur_score = nodes[cur_idx].score;
      const std::string cur_text = nodes[cur_idx].text;
      const std::vector<uint32_t> full_cps =
          Utf8ToCodepoints(prev_tail + cur_text);
      const size_t keep = full_cps.size() > gram_n ? full_cps.size() - gram_n : 0;
      const std::vector<uint8_t> ctx_enc =
          EncodeCodepoints(full_cps, keep, full_cps.size());
      const size_t ctx_len = full_cps.size() - keep;
      const std::string ctx_key =
          CodepointsToUtf8(full_cps, keep, full_cps.size());

      for (int j = i + 1; j <= n; ++j) {
        const std::string sub =
            code.substr(static_cast<size_t>(i), static_cast<size_t>(j - i));
        uint32_t first = 0, count = 0;
        if (!impl_->FindCode(sub, &first, &count) || count == 0) continue;
        // order = nullptr 表示记录连续（first..first+count）；限边时才建索引表
        const uint32_t* order = nullptr;
        uint32_t order_count = count;
        std::vector<uint32_t> limited;
        if (p.max_edges > 0 && static_cast<int>(count) > p.max_edges) {
          limited.reserve(count);
          for (uint32_t e = 0; e < count; ++e) limited.push_back(first + e);
          std::stable_sort(limited.begin(), limited.end(),
                           [&](uint32_t a, uint32_t b) {
                             return recs[a].weight > recs[b].weight;
                           });
          limited.resize(static_cast<size_t>(p.max_edges));
          order = limited.data();
          order_count = static_cast<uint32_t>(limited.size());
        }
        for (uint32_t e = 0; e < order_count; ++e) {
          const LexRec& rec = recs[order ? order[e] : (first + e)];
          const double weight = static_cast<double>(rec.weight);
          if (weight < p.min_weight) continue;
          const std::string word(word_pool + rec.word_off, rec.word_len);
          std::string qkey = ctx_key;
          qkey.push_back('\x1f');
          qkey += word;
          qkey.push_back(j == n ? '1' : '0');
          double qv = 0.0;
          auto qit = query_cache.find(qkey);
          if (qit != query_cache.end()) {
            qv = qit->second;
          } else {
            if (impl_->have_gram) {
              auto wit = word_cps_cache.find(word);
              if (wit == word_cps_cache.end()) {
                wit = word_cps_cache.emplace(word, Utf8ToCodepoints(word)).first;
              }
              const std::vector<uint32_t>& wcps = wit->second;
              const size_t wend = std::min(wcps.size(), gram_n);
              const std::vector<uint8_t> wenc =
                  EncodeCodepoints(wcps, 0, wend);
              qv = impl_->gram.Query(ctx_enc, ctx_len, wenc, wend, j == n, p);
            }
            query_cache.emplace(qkey, qv);
          }
          Node child;
          child.score = cur_score + std::log(std::max(weight, 1e-6)) -
                        kLogScale + qv;
          child.parent = cur_idx;
          child.text = cur_text + word;
          child.word = word;
          child.code_j = j;
          nodes.push_back(child);
          states[static_cast<size_t>(j)].push_back(
              static_cast<int>(nodes.size() - 1));
        }
      }
    }
    if (nodes.size() > 4000000) break;  // 安全阀（异常输入）
  }

  std::vector<int>& finals = states[static_cast<size_t>(n)];
  if (finals.empty()) return out;
  // 末位去重：同文本保最高分，插入序 = 首次出现在 finals 的顺序（同 Python）
  std::unordered_map<std::string, size_t> pos;
  std::vector<int> ranked;
  pos.reserve(finals.size() * 2);
  ranked.reserve(finals.size());
  for (size_t k = 0; k < finals.size(); ++k) {
    const int idx = finals[k];
    auto it = pos.find(nodes[idx].text);
    if (it == pos.end()) {
      pos.emplace(nodes[idx].text, ranked.size());
      ranked.push_back(idx);
    } else if (nodes[idx].score > nodes[ranked[it->second]].score) {
      ranked[it->second] = idx;
    }
  }
  std::stable_sort(ranked.begin(), ranked.end(), [&](int a, int b) {
    return nodes[a].score > nodes[b].score;
  });
  if (static_cast<int>(ranked.size()) > p.topk) ranked.resize(p.topk);
  for (size_t r = 0; r < ranked.size(); ++r) {
    Sentence s;
    s.score = nodes[ranked[r]].score;
    s.text = nodes[ranked[r]].text;
    for (int idx = ranked[r]; idx > 0; idx = nodes[idx].parent) {
      Sentence::Word w;
      w.word = nodes[idx].word;
      w.code_end = nodes[idx].code_j;
      s.words.push_back(w);
    }
    std::reverse(s.words.begin(), s.words.end());
    out.push_back(s);
  }
  return out;
}

}  // namespace ngram
}  // namespace rime_llm

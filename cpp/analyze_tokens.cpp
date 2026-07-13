/*
 * analyze_tokens.cpp — 统计拼读双拼词库中所有词条的 token 数分布
 * 加载 Qwen3.5 tokenizer，遍历 dict 中所有词条，统计 1/2/3-token 比例
 */
#define NOMINMAX
#include <windows.h>
#include "llama.h"

#include <string>
#include <vector>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <unordered_map>

int main() {
    printf("=== Token Distribution Analysis ===\n");

    // Init tokenizer via model (we need it for the vocab)
    llama_backend_init();
    llama_model_params mp = llama_model_default_params();
    mp.use_mmap = 1;
    auto* model = llama_model_load_from_file(
        "d:/gguf_models/Qwen3.5-0.8B-Q4_K_M.gguf", mp);
    if (!model) { printf("ERROR: load model\n"); return 1; }
    auto* vocab = llama_model_get_vocab(model);

    // Read dict
    std::ifstream f("C:/Users/Administrator/AppData/Roaming/Rime/pdsp.dict.yaml");
    if (!f.is_open()) {
        // Try alternative path
        f.open("d:/OneDrive/typing/拼读双拼/配置文件/pdsp.dict.yaml");
        if (!f.is_open()) {
            printf("ERROR: cannot open dict\n");
            return 1;
        }
    }

    std::string line;
    bool hdr = true;
    int total = 0;
    int cnt_1 = 0, cnt_2 = 0, cnt_3 = 0, cnt_4p = 0;
    // Track by word length too
    std::unordered_map<int, std::vector<int>> by_charlen; // charlen -> [tok_count, word_count]

    while (std::getline(f, line)) {
        if (hdr) { if (line == "...") hdr = false; continue; }
        if (line.empty() || line[0] == '#') continue;
        // Format: word\tencoding\t...
        size_t t1 = line.find('\t');
        if (t1 == std::string::npos) continue;
        std::string word = line.substr(0, t1);
        if (word.empty()) continue;

        // Tokenize
        std::vector<llama_token> toks(16);
        int n = llama_tokenize(vocab, word.c_str(), (int)word.size(),
                                toks.data(), (int)toks.size(), true, true);
        if (n < 0) {
            toks.resize(-n);
            n = llama_tokenize(vocab, word.c_str(), (int)word.size(),
                               toks.data(), (int)toks.size(), true, true);
        }
        if (n <= 0) continue;
        total++;

        if (n == 1) cnt_1++;
        else if (n == 2) cnt_2++;
        else if (n == 3) cnt_3++;
        else cnt_4p++;

        // Track by character length (approximate: byte length / 3 for UTF-8 Chinese)
        int char_len = 0;
        for (char c : word) if ((c & 0xC0) != 0x80) char_len++;
        by_charlen[char_len].push_back(n);
    }

    printf("\n=== Token count distribution (all %d words) ===\n", total);
    printf("1 token: %d (%.1f%%)\n", cnt_1, 100.0*cnt_1/total);
    printf("2 token: %d (%.1f%%)\n", cnt_2, 100.0*cnt_2/total);
    printf("3 token: %d (%.1f%%)\n", cnt_3, 100.0*cnt_3/total);
    printf("4+ token: %d (%.1f%%)\n", cnt_4p, 100.0*cnt_4p/total);

    printf("\n=== By character length ===\n");
    for (int cl = 1; cl <= 6; cl++) {
        if (by_charlen.find(cl) == by_charlen.end()) continue;
        auto& counts = by_charlen[cl];
        double avg = 0; for (int c : counts) avg += c; avg /= counts.size();
        int c1=0, c2=0, c3=0;
        for (int c : counts) {
            if (c==1) c1++; else if (c==2) c2++; else if (c==3) c3++;
        }
        printf("  %d-char words (%zu total): 1t=%.0f%% 2t=%.0f%% 3t=%.0f%% avg=%.2f\n",
               cl, counts.size(),
               100.0*c1/counts.size(), 100.0*c2/counts.size(),
               100.0*c3/counts.size(), avg);
    }

    // Specifically for 2-char words (most common in typing)
    if (by_charlen.find(2) != by_charlen.end()) {
        auto& c2w = by_charlen[2];
        int t1=0, t2=0;
        for (int c : c2w) { if (c==1) t1++; else if (c==2) t2++; }
        printf("\n=== 2-char words (typing focus): %zu total ===\n", c2w.size());
        printf("1-token: %d (%.1f%%), 2-token: %d (%.1f%%)\n",
               t1, 100.0*t1/c2w.size(), t2, 100.0*t2/c2w.size());
    }

    llama_model_free(model);
    llama_backend_free();
    printf("\nDone.\n");
    return 0;
}

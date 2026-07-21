from collections import defaultdict
from typing import List, Dict

# Classic T9 keypad
T9_MAP = {
    '2': 'abc', '3': 'def', '4': 'ghi', '5': 'jkl',
    '6': 'mno', '7': 'pqrs', '8': 'tuv', '9': 'wxyz'
}

class T9Predictor:
    def __init__(self, word_list: List[str]):
        self.trie: Dict = {}
        self._build(word_list)

    def _word_to_digits(self, word: str) -> str:
        digit_map = {}
        for d, letters in T9_MAP.items():
            for c in letters:
                digit_map[c] = d
        return ''.join(digit_map.get(c.lower(), '') for c in word if c.isalpha())

    def _build(self, words: List[str]):
        for word in words:
            word = word.strip().lower()
            if not word.isalpha():
                continue
            digits = self._word_to_digits(word)
            node = self.trie
            for d in digits:
                if d not in node:
                    node[d] = {}
                node = node[d]
            if 'words' not in node:
                node['words'] = []
            if word not in node['words']:
                node['words'].append(word)

    def predict(self, token: str, limit: int = 10) -> List[str]:
        """token = digit sequence, e.g. '843' → ['the', 'tie', ...]"""
        if not token or not token.isdigit():
            return []
        node = self.trie
        for d in token:
            if d not in node:
                return []
            node = node[d]
        return node.get('words', [])[:limit]
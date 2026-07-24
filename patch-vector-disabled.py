#!/usr/bin/env python3
"""
patch-vector-disabled.py

Patches open_webui/retrieval/vector/factory.py to support VECTOR_DB=disabled.
This allows Open WebUI to start without any vector database backend installed
(chromadb requires onnxruntime which has no s390x wheel).

RAG/knowledge features will return empty results when VECTOR_DB=disabled,
but chat, auth, and Ollama inference all work normally.
"""
import os

factory_path = os.path.join(
    os.path.dirname(__file__),
    'open_webui', 'retrieval', 'vector', 'factory.py'
)

original = open(factory_path).read()

if 'NullVectorDB' in original:
    print('  factory.py already patched, skipping')
else:
    patched = original.replace(
        'from open_webui.retrieval.vector.main import VectorDBBase\n'
        'from open_webui.retrieval.vector.type import VectorType',

        'from open_webui.retrieval.vector.main import (\n'
        '    GetResult, SearchResult, VectorDBBase, VectorItem\n'
        ')\n'
        'from open_webui.retrieval.vector.type import VectorType\n'
        'from typing import Optional, List, Any\n'
        '\n'
        '\n'
        'class NullVectorDB(VectorDBBase):\n'
        '    """No-op vector DB used when VECTOR_DB=disabled (e.g. s390x builds)."""\n'
        '    def has_collection(self, collection_name: str) -> bool: return False\n'
        '    def delete_collection(self, collection_name: str) -> None: pass\n'
        '    def search(self, collection_name: str, vectors: List[List[float | int]], limit: int) -> Optional[SearchResult]: return None\n'
        '    def query(self, collection_name: str, where: dict = {}, limit: Optional[int] = None) -> Optional[GetResult]: return None\n'
        '    def get(self, collection_name: str) -> Optional[GetResult]: return None\n'
        '    def insert(self, collection_name: str, items: List[VectorItem]) -> None: pass\n'
        '    def upsert(self, collection_name: str, items: List[VectorItem]) -> None: pass\n'
        '    def delete(self, collection_name: str, ids: Optional[List[str]] = None, filter: Optional[dict] = None) -> None: pass\n'
        '    def reset(self) -> None: pass',
    ).replace(
        '            case _:\n'
        '                raise ValueError(f\'Unsupported vector type: {vector_type}\')',

        '            case \'disabled\':\n'
        '                return NullVectorDB()\n'
        '            case _:\n'
        '                raise ValueError(f\'Unsupported vector type: {vector_type}\')',
    )

    if patched == original:
        print('ERROR: patch pattern not found in factory.py — check source version')
        raise SystemExit(1)

    open(factory_path, 'w').write(patched)
    print('✓ factory.py patched with NullVectorDB and VECTOR_DB=disabled support')

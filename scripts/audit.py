#!/usr/bin/env python3
"""Fail closed on common credential material and accidental home identity paths."""
from pathlib import Path
import re, sys
ROOT=Path(__file__).resolve().parents[1]
# Deliberately target credential-shaped values, not ordinary words in plugin code.
patterns=[
 ("private-key", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
 ("github-token", re.compile(r"(?:gho_|ghp_|github_pat_|github[_-]" + r"token\s*[:=])")),
 ("bearer-token", re.compile(r"(?i)bearer\s+[A-Za-z0-9._-]{16,}")),
 ("credential-assignment", re.compile(r"(?i)(?:password|passwd|secret|api[_-]?key|access[_-]?token)\s*[:=]\s*[\"']?[^\s\"']{8,}")),
 ("absolute-home-path", re.compile(r"/home/[A-Za-z0-9_.-]+")),
 ("email-address", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")),
]
issues=[]
for p in sorted(ROOT.rglob('*')):
 if not p.is_file() or '.git' in p.parts or p == Path(__file__): continue
 try: text=p.read_text(encoding='utf-8')
 except (UnicodeDecodeError,OSError): continue
 for name,rx in patterns:
  if rx.search(text): issues.append(f"{name}: {p.relative_to(ROOT)}")
if issues:
 print("AUDIT FAILED")
 print("\n".join(sorted(set(issues))))
 sys.exit(1)
print(f"AUDIT PASSED: scanned {sum(1 for p in ROOT.rglob('*') if p.is_file() and '.git' not in p.parts)} files")

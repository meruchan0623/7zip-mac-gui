#!/usr/bin/env python3
"""Audit explicit L/LF message keys and ArchiveError messages against the catalog.
Run after adding a new message. It never rewrites Swift or translates parameters.
"""
import argparse,json,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');parser.add_argument('--sync',action='store_true',help='Generate English and Traditional Chinese resources');args=parser.parse_args()
catalog=json.loads((ROOT/'Resources/Localization/zh-Hans.json').read_text())
if args.sync:
 english = {key:key.replace('SevenZip Mac','7zip Mac') for key in catalog}
 (ROOT/'Resources/Localization/en.json').write_text(json.dumps(english,ensure_ascii=False,indent=2)+'\n')
 swift = r'''import Foundation
let root = URL(fileURLWithPath:CommandLine.arguments[1])
let data = try Data(contentsOf:root.appendingPathComponent("zh-Hans.json"))
let source = try JSONDecoder().decode([String:String].self,from:data)
let transformed = source.mapValues { $0.applyingTransform(StringTransform("Hans-Hant"),reverse:false) ?? $0 }
let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
try encoder.encode(transformed).write(to:root.appendingPathComponent("zh-Hant.json"))
'''
 subprocess.run(['xcrun','swift','-e',swift,str(ROOT/'Resources/Localization')],check=True)
missing={}
for folder in ['Sources/SevenZipMac','Sources/ArchiveCore']:
 for path in (ROOT/folder).glob('*.swift'):
  if path.name in ['Localization.swift','UIWorkflowChecks.swift','UIWorkflowIntegrationChecks.swift']:continue
  for match in re.finditer(r'(?:\bL[F]?\(|ArchiveError\.(?:invalid|io)\(|\b(?:FormDialog|prompt|confirm|saveURL|chooseDirectory)\(|\.(?:field|popup|check|note|path)\(|UIError\(message:\s*|\bprogress\(|\.finish\(message:\s*|placeholderString\s*=\s*|NSButton\(title:\s*|NSTextField\(labelWithString:\s*|\.messageText\s*=\s*|\.informativeText\s*=\s*|\.title\s*=\s*|\bmessage:\s*|\bwithTitle:\s*|\.multiline\()\s*"((?:[^"\\]|\\.)*)"',path.read_text()):
   key=re.sub(r'\\\([^)]*\)','%@',match[1]).replace('\\n','\n').replace('\\t','\t').replace('\\"','"')
   # Parenthesized interpolations can contain nested calls: known templates
   # are assessed by their leading literal as well as their full key.
   if key.startswith(('FAIL:', 'PASS:')) or key == 'Real-engine regression timed out.':continue
   key = key.replace('%@))', '%@')
   if key not in catalog and key.strip():
    missing.setdefault(key,[]).append(str(path.relative_to(ROOT)))
for key,paths in sorted(missing.items()):print(json.dumps(key,ensure_ascii=False)+' — '+', '.join(sorted(set(paths))))
print(f'{len(catalog)} catalog entries; {len(missing)} untranslated explicit keys')
if args.check and missing:raise SystemExit(1)

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swift build -c release
CORE_BIN=$(swift build -c release --show-bin-path)
swiftc -I "$CORE_BIN" -I "$CORE_BIN/Modules" -L "$CORE_BIN" -lGlacierCore -swift-version 5 -O -parse-as-library Sources/SpeechCapture.swift Sources/SentenceFeed.swift Sources/GPTTranslator.swift Sources/CaptionHistory.swift Sources/LectureArchive.swift Sources/WordExporter.swift Tests/ArchiveVerify.swift -o .build/verify-archive
.build/verify-archive

python3 - <<'PYQA'
from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET
path = Path('.build/archive-output-path.txt').read_text()
with ZipFile(path) as archive:
    assert archive.testzip() is None, 'Corrupt DOCX ZIP member'
    root = ET.fromstring(archive.read('word/document.xml'))
    ns = {'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
    paragraphs = [''.join(n.text or '' for n in p.findall('.//w:t', ns)) for p in root.findall('.//w:p', ns)]
    text = '\n'.join(paragraphs)
    expected = ['中文课堂总结', '思维导图', 'Key Knowledge Outline', '完整英文转录', '完整中文翻译']
    positions = [paragraphs.index(title) for title in expected]
    assert positions == sorted(positions), 'Study notes and full transcript sections out of order'
    assert 'WhisperKit' in text and '来源 Wispr Note' not in text
    english = '\n'.join(paragraphs[positions[-2]:positions[-1]])
    assert all('Example %s.' % n in english for n in range(1, 23)), 'English source paragraphs missing'
    assert archive.read('word/media/mindmap.png').startswith(b'\x89PNG\r\n\x1a\n')
print('PASS: independent DOCX reader validates CRC, Unicode, complete English-before-Chinese ordering and mind map')
PYQA

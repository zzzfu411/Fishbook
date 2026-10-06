#!/bin/zsh
set -euo pipefail
CHECK_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$CHECK_ROOT"
CHECK_PUBLIC=0
CHECK_PDF=0
CHECK_GUI=0
for option in "$@"; do
  case "$option" in
    --public) CHECK_PUBLIC=1 ;;
    --pdf) CHECK_PDF=1 ;;
    --gui) CHECK_PDF=1; CHECK_GUI=1 ;;
    *) print -u2 'Usage: zsh tools/check.sh [--public] [--pdf|--gui]'; exit 2 ;;
  esac
done
[[ -f content/library.json && -f tools/build_documents.py ]] || CHECK_PUBLIC=1
mkdir -p build/ModuleCache
CORE=(Sources/Models.swift Sources/LibraryStorage.swift)
PDF_CORE=("${CORE[@]}" Sources/Theme.swift Sources/PDFColors.swift Sources/PDFAnnotations.swift Sources/PDFReader.swift)
CHECK_RESOURCES="$CHECK_ROOT"
if [[ "$CHECK_PUBLIC" == 1 ]]; then
  CHECK_RESOURCES="$(mktemp -d "$CHECK_ROOT/build/public-test-XXXXXX")"
  trap 'rm -rf -- "$CHECK_RESOURCES"' EXIT
  ditto content/public "$CHECK_RESOURCES/content"
  ditto content/reader-vendor "$CHECK_RESOURCES/content/reader-vendor"
  swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${CORE[@]}" Sources/Documents.swift Sources/PDFAnnotations.swift Tests/PublicLibrary.swift -o build/public-library
  build/public-library "$CHECK_RESOURCES"
else
  python3 tools/build_documents.py --check
  swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${CORE[@]}" Tests/Smoke.swift -o build/smoke
  build/smoke "$CHECK_ROOT"
fi
swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${CORE[@]}" Tests/ReaderWorkflow.swift -o build/reader-workflow
build/reader-workflow "$CHECK_RESOURCES"
swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${CORE[@]}" Tests/StorageWorkflow.swift -o build/storage-workflow
build/storage-workflow
swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${CORE[@]}" Sources/LibraryFeatures.swift Tests/LibraryFeaturesSmoke.swift -o build/library-features-smoke
build/library-features-smoke
if [[ "$CHECK_PUBLIC" == 0 ]]; then
  swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${CORE[@]}" Sources/Documents.swift Tests/DocumentsSmoke.swift -o build/documents-smoke
  build/documents-smoke "$CHECK_ROOT"
fi
swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${CORE[@]}" Sources/Documents.swift Tests/DocumentRevisions.swift -o build/document-revisions
build/document-revisions "$CHECK_ROOT"
swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${CORE[@]}" Sources/MarkdownView.swift Tests/MarkdownSmoke.swift -o build/markdown-smoke
build/markdown-smoke "$CHECK_RESOURCES"
node Tests/ReaderLifecycle.js
swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache Sources/ReaderWindow.swift Tests/ImmersiveReading.swift -o build/immersive-reading
build/immersive-reading
swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache Sources/Theme.swift Sources/ImmersiveToolbar.swift Tests/ImmersiveToolbarChecks.swift -o build/immersive-toolbar
build/immersive-toolbar
swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache Sources/CitationGraph.swift Tests/CitationGraphChecks.swift -o build/citation-graph
build/citation-graph
if [[ "$CHECK_PDF" == 1 ]]; then
  swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${CORE[@]}" Sources/PDFAnnotations.swift Tests/PDFAnnotationChecks.swift -o build/pdf-annotations
  build/pdf-annotations
  if [[ "$CHECK_PUBLIC" == 0 ]]; then
    swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${PDF_CORE[@]}" Sources/LibraryFeatures.swift Sources/PDFNavigationPane.swift Tests/PDFNavigation.swift -o build/pdf-navigation
    build/pdf-navigation "$CHECK_ROOT"
  fi
  swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${PDF_CORE[@]}" Tests/PDFToolsWorkflow.swift -o build/pdf-tools-workflow
  build/pdf-tools-workflow
  if [[ "$CHECK_PUBLIC" == 0 ]]; then
    swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${PDF_CORE[@]}" Tests/PDFLayout.swift -o build/pdf-layout
    build/pdf-layout "$CHECK_ROOT"
  fi
  swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${PDF_CORE[@]}" Tests/PDFColorChecks.swift -o build/pdf-colors
  build/pdf-colors
fi
if [[ "$CHECK_GUI" == 1 ]]; then
  swiftc -swift-version 5 -parse-as-library -module-cache-path build/ModuleCache "${CORE[@]}" Sources/MarkdownView.swift Tests/ReaderContext.swift -o build/reader-context
  build/reader-context
fi
print '所有请求的检查通过。测试只使用临时资料目录。'

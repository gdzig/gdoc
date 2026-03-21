## [0.1.0] - 2026-03-21

### 🚀 Features

- Add parsing for constants, signals, and enums in class documentation
- Parse and display descriptions for methods, properties, signals, constants, and enums
- Add zig-xml dependency for XML doc parsing
- Add Godot version string parser
- Run godot --version and parse output
- Add tarball download, XML extraction, and cache markers
- Add XML doc parser for Godot class documentation
- Add tutorials field to Entry and render in markdown output
- Integrate XML doc supplementation into cache flow
- Add terminal spinner during XML doc download
- Add spinner for cache building phase
- Parse method params, return type, and qualifiers from XML
- Parse property type and default value from XML
- Parse constructors and operators from XML
- Parse constant value and enum attribute from XML
- Update EntryKind and Entry for XML doc support
- Add loadFromXmlDir to build DocDatabase from XML files
- Update markdown generation for inherits, qualifiers, default values
- Convert Godot BBCode cross-refs and codeblocks to Markdown
- Add automated release task with version bumping and changelog generation

### 🐛 Bug Fixes

- Skip XML fetch and merge when GDOC_NO_XML is set
- Use cross-platform env var check with fixed buffer allocator
- Use makePath for recursive directory creation in cache

### 🚜 Refactor

- Consolidate signal, constant, and enum parsers into generic functions
- Extend generic parseEntry to handle methods and properties
- Replace Config singleton with explicit *const Config parameter
- Remove all JSON parsing code from DocDatabase
- Remove JSON codepaths, simplify to XML-only architecture

### 📚 Documentation

- Add XML documentation supplementation design spec
- Address spec review feedback
- Add XML doc supplementation implementation plan
- Require Godot to be installed for XML supplementation
- Add design spec for replacing JSON with XML as primary doc source
- Address spec review feedback
- Address round 2 spec review feedback
- Drop builtin_class distinction from spec
- Add implementation plan for XML-only doc source migration
- Update implementation plan after review feedback
- Update CLAUDE.md to reflect XML-only architecture

### 🧪 Testing

- Add snapshot test for tutorials rendering
- Add integration roundtrip test and error-path tests
- Add snapshot tests for Godot BBCode conversion

### ⚙️ Miscellaneous Tasks

- Bump minimum zig version
- Update zigdown
- Add .worktrees to gitignore
- Remove plan and spec documents
- Remove design docs and implementation plans
- Integrate git-cliff to generate changelog-based release notes
## [0.0.1] - 2025-11-24

### 🚀 Features

- Basic DocDatabase struct that can parse builtin_classes from a basic JSON string
- Basic class parsing
- Setting parent_index on methods attached to classes
- Parsing utility functions
- Member indices
- Convert class brief description into markdown
- GetCacheDir
- GetJsonCachePath
- GetParsedCachePath
- EnsureCacheDir
- CacheHeader struct
- Cache file saving and loading
- Clear cache
- Api.generateApiJson
- Cli for clearing cache and stubbed symbol lookup
- Implement cache loading with validation and test coverage
- Add direct API file lookup bypassing cache system
- Improve JSON parser robustness with graceful unknown field handling
- Add brief description support and improved documentation formatting
- Add terminal output format support with automatic TTY detection
- Implement writeSymbolMarkdown function with comprehensive test coverage
- Add comprehensive markdown cache generation and reading functionality
- Add automatic markdown cache generation and population
- Add structured member listings for classes in documentation generation
- Include function signatures in generated documentation

### 🐛 Bug Fixes

- Handle unknown root-level keys in JSON parser
- Add missing deinit call to prevent memory leak
- Duplicate enum entry

### 💼 Other

- Known-folders dependency
- Add zli
- Cache generation
- Add zigdown

### 🚜 Refactor

- Move getCacheDir to cache.zig
- Remove old binary cache system in favor of markdown-based cache

### 📚 Documentation

- Add MIT license file
- Remove GodotZig copyright
- Adds readme and placeholder contributing

### 🧪 Testing

- Failing test for parsing classes from json
- Failing test for basic utility functions
- Member indices
- Add comprehensive unit tests for resolveSymbolPath function
- Add snapshot testing for markdown generation
- Add integration test for markdown cache functionality
- Add expected snapshots
- Fix test running godot to export extension api

### ⚙️ Miscellaneous Tasks

- Init project
- Implementation planning
- Ignore local claude settings
- Remove .claude/settings.local.json
- Add mise task for zig build test
- Bump zig to 0.15.2
- Add bbcodez module to root module
- Issues
- Lower priority for bugs
- Add build/release workflows
- Update bbcodez to use new repo
- Bump version to 0.0.1

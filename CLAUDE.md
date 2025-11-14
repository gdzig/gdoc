# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Note**: This project uses [bd (beads)](https://github.com/steveyegge/beads) for issue tracking. Use `bd` commands instead of markdown TODOs. See AGENTS.md for workflow details.

## Project Overview

**gdoc** is a CLI documentation viewer for Godot API documentation, similar to `zigdoc`. It parses Godot's API documentation and displays it in the terminal with BBCode-to-Markdown conversion.

Key behavior:
- Uses the user's local `godot` executable if available
- Falls back to downloading the latest API JSON from GitHub into cache if Godot is not installed
- Converts BBCode documentation to Markdown using the `bbcodez` library for terminal display

## Build System

### Dependencies
- **Zig**: 0.15.1 (managed via mise)
- **ZLS**: 0.15.0 (Zig Language Server, managed via mise)
- **bbcodez**: BBCode parser/formatter library (fetched from git)

### Common Build Commands

```bash
# Build the executable
zig build

# Run the application
zig build run

# Run with arguments
zig build run -- <symbol>

# Run tests (both module and executable tests)
zig build test

# Install to zig-out/bin/
zig build -Doptimize=ReleaseSafe
```

### Build Configuration

The project uses a dual-module architecture:
1. **gdoc module** (`src/root.zig`) - Core library functionality
2. **gdoc executable** (`src/main.zig`) - CLI interface

Both modules have separate test suites that run in parallel via `zig build test`.

The build system imports `bbcodez` as a dependency and makes it available to the executable's root module.

## Architecture

### Module Structure
- **src/main.zig**: CLI entry point, argument parsing, user interaction
- **src/root.zig**: Core library with API fetching, parsing, and display logic

### Expected Data Flow
1. Parse CLI arguments for symbol lookup (e.g., `gdoc Node2D.position`)
2. Locate Godot API JSON:
   - Check for local `godot` executable → run `godot --dump-extension-api`
   - If not found → download from GitHub to cache directory
3. Parse JSON to find requested symbol documentation
4. Convert BBCode documentation to Markdown using `bbcodez`
5. Display formatted output to terminal

### Integration with bbcodez

The `bbcodez` dependency provides:
- BBCode tokenization and parsing
- Markdown formatter for converting parsed BBCode to Markdown
- Handles Godot's BBCode tags: `[b]`, `[i]`, `[code]`, `[url]`, etc.

Import in source files:
```zig
const bbcodez = @import("bbcodez");
```

## Project Management

This project uses **beads** (bd) for issue tracking. The `.beads/` directory contains the SQLite database.

```bash
# View beads workflow
bd workflow

# List open issues
bd list

# Show ready-to-work tasks
bd ready

# Create new issue
bd create "Issue title"

# Update issue status
bd update <issue-id> --status in_progress
```

## Development Environment

Uses `mise` for version management (see `mise.toml`):
- Zig 0.15.1
- ZLS 0.15.0  
- beads (bd CLI)

Install tools: `mise install`

## Reference Implementation

This project should behave similarly to `zigdoc`:
- `zigdoc std.ArrayList` → shows ArrayList documentation
- `gdoc Node2D` → should show Node2D class documentation
- `gdoc Node2D.position` → should show the position property documentation

Key zigdoc features to emulate:
- Symbol lookup with dot notation
- Clean terminal formatting
- Helpful error messages for symbol not found

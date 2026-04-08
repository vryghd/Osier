# Osier — Project Blueprint

> **Version:** 0.1.0-alpha  
> **Created:** April 8, 2026  
> **Author:** Christian Hill  
> **Status:** 🟡 In Development — Module D Active

---

## Overview

**Osier** is a native iOS system utility that acts as a direct-to-hardware local agent. It uses a local Gemma model (with optional BYOK for paid models) to manage files, external drives, native system databases, and personal vaults — entirely on-device, with no cloud intermediaries, no third-party shortcuts, and no copy-paste workflows.

---

## Core Philosophy

| Principle | Implementation |
|---|---|
| **Local-first** | All processing via on-device Gemma (Core ML) by default |
| **No cloud intermediaries** | Direct iOS framework access (PhotoKit, EventKit, FileProvider) |
| **Confirmation-first** | Nothing executes without explicit user sign-off |
| **No hard deletes** | All deletions route to system Trash / Recently Deleted |
| **Ad-free guarantee** | No tracking SDKs, ever |

---

## Architecture

```
Osier/
├── App/                        # Entry point, root scene
├── Modules/
│   ├── SafetyProtocol/         # ✅ Module D — BUILT FIRST (foundation)
│   │   ├── ActionPlan.swift
│   │   ├── SafetyProtocolEngine.swift
│   │   └── ConfirmActionCard.swift
│   ├── FileManager/            # 🔲 Module A — File & Hardware Manager
│   ├── VaultAgent/             # 🔲 Module B — Notes & Calendar Agent
│   └── GalleryAgent/           # 🔲 Module C — Photo Library Agent
├── LLMEngine/                  # 🔲 Local Gemma + BYOK integration
├── UI/
│   ├── Dashboard/              # Storage visualization
│   ├── ActionCenter/           # One-tap utility buttons
│   └── CommandBar/             # Persistent text input
├── Models/                     # CoreData models, data structs
└── Resources/                  # Assets, .mlpackage model files
```

---

## Feature Modules

### ✅ Module D — Safety & Trash Protocol *(Foundation — Build First)*

The governing safety layer that every other module depends on. All agent actions are structured as `ActionPlan` objects and require explicit user confirmation before any execution.

**Key rules:**
- Agent **builds** a plan → User **confirms** → Engine **executes**
- `FileManager.trashItem()` used instead of `removeItem()` for all file deletions
- `PHPhotoLibrary.performChanges` routes photo deletions to "Recently Deleted"
- Every action is logged to an in-session audit trail

**Files:**
- `ActionPlan.swift` — Data models (`ActionPlan`, `ActionItem`, `AgentActionType`, `RiskLevel`)
- `SafetyProtocolEngine.swift` — `@MainActor` execution engine with `pendingPlan` state
- `ConfirmActionCard.swift` — SwiftUI confirmation overlay card

---

### 🔲 Module A — File & Hardware Manager

- External SSD/SD card detection via `FileProvider`
- One-tap Move to External Drive
- PDF creation and modification via `PDFKit`
- Background folder sync to iCloud or hardware via `BackgroundTasks`

**Key frameworks:** `FileProvider`, `PDFKit`, `BackgroundTasks`, `CloudKit`, `UniformTypeIdentifiers`

---

### 🔲 Module B — Direct-to-Vault Integration

- Write directly to `.md` files in Obsidian vault format (zero copy-paste)
- Write to native Apple Notes
- Full `EventKit` read/write for Calendar and Reminders
- Workflow: Scan daily plan → snooze low-priority reminders → propose calendar blocks

**Key frameworks:** `EventKit`, `Foundation` (FileManager for .md files)

---

### 🔲 Module C — Gallery Agent

- Native `PhotoKit` integration — operates inside Apple Photos, not a secondary gallery
- Smart album creation via EXIF metadata, date, location, and object recognition (`Vision`)
- Example command: *"Find all photos of my Durango from track day and put them in Track Day album"*
- Storage recovery: detect blurry, duplicate, or oversized media

**Key frameworks:** `PhotoKit`, `Vision`, `CoreImage`

---

## LLM Engine

| Mode | Model | Use Case |
|---|---|---|
| **Local (Default)** | Gemma `.mlpackage` via Core ML | All offline processing, command parsing |
| **BYOK — GPT-4** | OpenAI API (user key) | Heavy multi-step reasoning |
| **BYOK — Claude** | Anthropic API (user key) | Heavy multi-step reasoning |

Local file access and execution are always retained regardless of which LLM is active.

---

## UI System

| Component | Description |
|---|---|
| **System Dashboard** | Visual storage breakdown: Internal / iCloud / External |
| **Action Center** | One-tap buttons: Quick Sort, Quick Move, Clear Downloads, Backup Vault |
| **Command Bar** | Persistent bottom text input for multi-step agent commands |
| **Confirm Action Card** | Modal overlay (Module D) presented before every mutating action |

**Design language:** Premium system utility — dark, glassy, minimal. No chatbot bubble UI.

---

## iOS Project Settings

| Setting | Value |
|---|---|
| **Language** | Swift |
| **Interface** | SwiftUI |
| **Minimum iOS** | 17.0 |
| **Bundle ID** | `com.yourname.osier` |
| **Xcode Target** | iOS App |

### Linked Frameworks

| Framework | Purpose |
|---|---|
| `Photos` / PhotoKit | Gallery Agent — native photo library |
| `EventKit` | Calendar and Reminders read/write |
| `AppIntents` | Siri / Spotlight integration |
| `PDFKit` | On-device PDF creation and editing |
| `CoreML` | Local Gemma model inference |
| `NaturalLanguage` | On-device command parsing |
| `Vision` | EXIF and object detection for photos |
| `CoreData` | Local structured data persistence |
| `FileProvider` | External SSD / SD card access |
| `UniformTypeIdentifiers` | File type identification |
| `BackgroundTasks` | Background backup jobs |
| `CloudKit` | iCloud sync for vault backups |

### Required Info.plist Keys

```xml
NSPhotoLibraryUsageDescription
NSPhotoLibraryAddUsageDescription
NSCalendarsUsageDescription
NSRemindersUsageDescription
UISupportsDocumentBrowser → true
LSSupportsOpeningDocumentsInPlace → true
```

### Capabilities

- iCloud (CloudKit + iCloud Documents)
- Background Modes (Background fetch + Background processing)
- App Groups
- Siri

---

## Monetization

**Ad-free. Always.**

| Tier | Price | Features |
|---|---|---|
| **Base (Free)** | $0 | File moving, basic sorting, trash routing, local Gemma |
| **Premium (Paid)** | TBD | Gallery sorting, SSD automation, EventKit/Obsidian integration, BYOK |

---

## Development Roadmap

- [x] Project initialized in Xcode
- [x] Module D: Safety & Trash Protocol — `ActionPlan`, `SafetyProtocolEngine`, `ConfirmActionCard`
- [ ] Module A: File & Hardware Manager
- [ ] Module B: Vault & Calendar Agent
- [ ] Module C: Gallery Agent
- [ ] LLM Engine: Local Gemma integration (Core ML)
- [ ] LLM Engine: BYOK plug-in (GPT-4 / Claude)
- [ ] UI: System Dashboard
- [ ] UI: Action Center + Command Bar
- [ ] App Store submission prep

---

## Git

- **Branch:** `master`
- **Remote:** GitHub
- **Commit policy:** Stage, commit, and push after every meaningful change

---

*This document lives at the root of the Osier project and should be updated as each module is completed.*

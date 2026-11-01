# Compiler-building tools

These are tools used to generate code and related artifacts for the Phase 2 (self-hosted) compiler.

This directory holds **JSON-LD agent specifications** (GAB / AALang–style graphs). In compatible AI-assisted workflows—typically by opening a given `.jsonld` file as the task context—the assistant follows that graph as a **specialized “tool agent”** for compiler work: structured prompts, modes, and guardrails rather than ad hoc chat.

You do not need every file for day-to-day hacking; pick the graph that matches what you are doing. At a high level:

| Area                              | Examples (file names) |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Compiler pipeline scaffolding** | Code generators / builders for the major phases—`silica-lexer-code-generator`, `silica-parser-code-generator`, `silica-typechecker-code-generator`, `silica-effect-code-generator`, `silica-sir_generator_builder`, `silica-codegen-code-generator`, `silica-emitter_builder`, plus `main_generator` for wiring a `main` entry. |
| **Planning and integration**      | `silica-compiler-phase-planning-tool` (phase design and coordination), `silica-CI` (driving CI-style checks), `golden-fail-generator` (golden / failure test workflows around trial outputs), `silica-compiler-trial-generator` (authoring `.silica` trials: compile-fail → `error_enforcement_addition`, success → behavior subdir), `silica-module-checker-debug-tool` (spec- and source-grounded debugging for the module checking phase).                                                                                          |
| **Documentation**                 | `silica_doc_generator` — guided doc generation aligned with project conventions.                                                                                                                                                                                                                                                |
| **Focused design discussions**    | `tuple_recursion_discussion`, `memory_regions_discussion`, `device-io-sequence-block-tool` — structured exploration of specific language and runtime topics.                                                                                                                                                                    |

Individual graphs contain their own execution instructions; treat them as **executable playbooks** for the assistant, not plain documentation.

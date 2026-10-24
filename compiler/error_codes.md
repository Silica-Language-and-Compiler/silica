# Silica Compiler Error Code Allocation

Per silica-error-code-scheme.jsonld and silica-specification.md §1.6.

## Phase Allocations

| Phase | Range | Category | Spec Section |
|-------|-------|----------|--------------|
| Lexer | E0001-E0999 | LexicalErrors | spec:§2 |
| Parser | E1000-E1999 | ParseErrors | spec:§3 |
| Type checker | E2000-E2999 | TypeErrors | spec:§6 |
| Effect checker | E3000-E3999 | EffectErrors | spec:§8 |
| SIR generator | E4000-E4049 | CodegenErrors (SIR) | - |
| Emitter | E4050-E4099 | CodegenErrors (emit) | - |
| Module | E5000-E5999 | ModuleErrors | spec:§11 |
| Internal | E9000-E9999 | InternalErrors | - |

## Specific Codes (emitted by the compiler; mirrors silica-error-code-scheme.jsonld)

Codes with several meanings list each meaning on one line, separated by semicolons.

### Lexer (E0001-E0999)
The lexer stops at the first lexical error and the driver reports it as a `LexicalError` before parsing (spec §2.5). `|` and `?` still reach the parser as unknown-character tokens (sum types, `ref?`).
- E0001 UnexpectedCharacter — a character that begins no token outside string, character and atom literals and comments: ASCII punctuation outside spec §2.2.4 (`$`, `&`, `#`, backtick, `\`, `~`, `^`), a control character such as NUL, a non-ASCII character, or a byte order mark after the first character (a leading byte order mark is skipped) (spec §2.1, §2.2)
- E0002 InvalidEscapeSequence — a backslash in a string or character literal that starts none of the escapes of spec §2.2.3 (`\\ \' \" \n \t \r \e \xHH`)
- E0003 UnterminatedStringLiteral — a string literal with no closing `"` before the end of the file
- E0004 UnterminatedCharacterLiteral — a character literal with no closing `'` after its one character or escape, or the empty literal `''`
- E0005 InvalidNumericLiteral — `0x` or `0b` without digits, a float exponent without digits, `1.` before the end of the file, `;`, `)`, `,` or `]`, a second `.` (`1.5.2`), or a literal followed directly by a letter, digit or `_` (`12abc`, `0x1G`, `0b102`, `1_000`, `1e5`) (spec §2.2.3)
- E0006 UnterminatedBlockComment — a `{-` block comment with no closing `-}` before the end of the file (spec §2.3.2)
- E0007 InvalidUtf8 — the source bytes do not form UTF-8 (a lone continuation byte, a lead byte C0, C1 or F5-FF, a truncated sequence, an overlong form, a surrogate, or a value above U+10FFFF), anywhere in the file including literals and comments (spec §2.1)

### Parser (E1000-E1999)
- E1000 ParseErrorDefault — uncategorized syntactic defect (statement-boundary fall-through when the next token does not start another statement)
- E1001 ParseFailureNoCode — fallback reported by the driver when parsing failed and the parser supplied no code of its own
- E1009 UnknownModuleInUse — `use` names a module that is not in the configured file set (module checker, spec 19.3)
- E1010 QualifiedCallWithoutUse — a module-qualified call has no matching `use` for its module prefix, or the prefix does not match the `use` spelling (module checker, spec 19.3)
- E1011 CallNotInExportSurface — a cross-module call names a function that the target module does not export (module checker, spec 19.2)
- E1040 MissingStatementTerminator — expected `;` after a statement before the next statement
- E1041 UnexpectedTrailingSemicolon — the last expression in a block must not be followed by `;`
- E1042 MissingReturnType — function declaration without `-> <type>` before its body
- E1043 BindingNameColonSpacing — a variable declaration name must be followed immediately by `:` with no whitespace
- E1044 AtomLiteralSpacing — atom literal `:` must be followed immediately by the atom name with no whitespace
- E1045 MissingFnPrefix — function declaration is missing the `fn` prefix
- E1046 UnexpectedTokenAfterRecordItems — unexpected token after the last item in a struct/record; close it with `}`
- E1047 NamedStructOrTypeAlias — named struct declaration or named type alias declaration is not allowed; types are declared inline where used
- E1048 ProducesWithoutSequence — `produces` appears without a preceding `sequence`
- E1049 SequenceMissingProduces — sequence block is missing `produces`
- E1050 ProducesMissingPure — sequence `produces` clause is missing `pure`
- E1051 SequenceMissingEnd — sequence block is missing its closing `end`
- E1052 DuplicateSequenceKeyword — duplicate `sequence` keyword in a sequence block
- E1053 DuplicateProducesKeyword — duplicate `produces` keyword in a sequence block
- E1054 ExtraEndAfterSequence — extra `end` after a sequence block
- E1055 UnusedVariable — a binding is never used in its scope (use it, pass it on, return it, or bind it as `_`)
- E1056 EmptyProcOnPureSequence — empty `proc[]` on a pure sequence block
- E1057 SequenceAsArrowRhs — sequence...produces pure...end cannot be the right-hand side of `->`; use a `{ ... }` block
- E1058 ReservedKeywordAsBindingName — a reserved keyword used as a variable binding name
- E1059 ReservedKeywordAsFieldName — a reserved keyword used as a record field name
- E1060 UnbalancedDelimiters — unbalanced brackets, braces or parentheses
- E1061 NamedStructConstruction — named struct construction is not allowed; use an anonymous record `{ field: ... }`
- E1062 IncompleteListReturnType — `List` return type written without type arguments before the function body
- E1063 UnclosedListTypeBracket — `List[` type with no matching `]`
- E1064 UnbracedMultiStatementArm — a multi-statement case arm must be wrapped in `{ ... }`
- E1065 UnclosedFunctionParameterList — function body `{` began before `)` closed the parameter list
- E1066 IfOutsideCaseGuard — `if` is only valid as a case-arm guard
- E1067 ReturnedCapturingFunctionLiteral — a function literal that captures local bindings cannot be returned from the function that owns them
- E1068 IntrinsicNamedFunction — a module function or export line is named after an actor runtime intrinsic (`link`, `monitor`, `demonitor`; spec 15.4.8.5-15.4.8.6), which `Q@name(...)` always resolves to instead of the export
- E1069 FunctionBodyNotParsed — a function declaration whose body the parser could not extract (for example a qualified call whose function name is a keyword)
- E1070 FunctionTooManyParameters — a function has more than 8 parameters (parse time)
- E1071 FunctionLiteralMissingReturnType — a function literal has no `-> type` before its body (the return type is never inferred, and the retired `: type` form is rejected; spec 3.3.6)
- E1072 UnsupportedFunctionLiteralCapture — a function literal captures a binding that is not an integer-typed binding of an integer literal where the literal is written (a parameter, a computed value, a non-integer literal, a rebound name or an enclosing literal's formal); closure environments are not supported (spec 3.3.6)
- E1080 ForeignDeclarationSyntax — malformed FFI surface (for example wrapper_meta not followed by a string literal path and `;`)

### Type checker (E2000-E2999)
- E2000 TypeErrorDefault — fallback reported by the driver when type checking failed and no code was supplied
- E2001 TypeMismatch — a literal does not fit the expected type (atom literal needs an atom type; unit literal; numeric literal where char or string is required; integer literal required, got float literal)
- E2002 UndefinedIdentifier — undefined identifier; also the misspelling `bool` where `boolean` was meant
- E2003 TypeUnificationFailure — a type does not match the expected type (many sites): builtin or call result type differs from the expected type, invalid return type, record or tuple literal matches no variant, malformed inline record type, argument type mismatch, no trait implementation matches an argument, negation not supported for unit
- E2004 UnknownOperator — unknown operator
- E2005 InvalidCaseOrBuiltinShape — structural errors, several meanings: invalid or unsupported case pattern; case pattern does not match scrutinee type; malformed case branch; case on boolean must cover true and false or include a wildcard; case with no branch; cannot infer scrutinee, field or struct-literal type; wrong argument count for a builtin (expects N arguments); builtin requires a tuple type; actor behavior must take (message, state) or must be a function; ill-formed struct literal; no such field; unknown list, region, collection or actor builtin; tuple decomposition shape mismatch; internal dispatcher miss
- E2006 InvalidTypeUse — `unit` is not a valid return type or variable/parameter type; single-element tuples are not allowed; lambda parameter needs an explicit type
- E2007 UnknownFunction — unknown function, or an unqualified call to a function defined only in another module (imported functions are called module-qualified); also unknown behavior function in spawn builtins
- E2008 CaseMissingCatchAllArm — a case over an integer type or string must end with a typed catch-all arm `_: T ->` (a bare `_ ->` does not count); also a catch-all arm that is not last
- E2009 SumRecordVariantFieldTypeConflict — record variants in one sum type share a field name with different types
- E2010 InvalidMemoryRegionType — invalid memory region type or declaration: buf/ref parameter count, empty region or element type, invalid memory space, runtime length identifier, read_ref/read_buf operand types, alloc_region space, rec outside any tuple type (binding annotation today; record field, parameter type and return type to follow: rec binds to the innermost enclosing tuple type and an unbound rec is an error)
- E2011 IntegerLiteralOutOfRange — integer literal is out of range for its type
- E2012 TupleDecomposeBindingOverflow — tuple decomposition pattern has more elements than the register file supports
- E2013 UnaryMinusNotAllowed — unary minus is not allowed; use negate_<type>(...)
- E2014 CaseGuardDoesNotDependOnBindings — a case guard does not depend on the arm's bindings
- E2015 CollectionMissingMemorySpace — a collection builtin requires an explicit `mem(Space)`
- E2016 EmptyListRequiresTypedBinding — empty[...]() needs a typed List binding, or the List type cannot be resolved
- E2017 CollectionConstructorTypeError — collection constructor error: missing or ill-typed compare_item / compare_node / compare_edge_data / compare_key / compare_value witness, constructor must call empty/1 or with_root/2, invalid OrderedSet/OrderedMap/Heap/SearchTree/Tree type declaration
- E2018 BindingMissingTypeAnnotation — a variable binding has no type annotation
- E2019 MainReturnTypeInvalid — main must return an integer, float or atom
- E2020 AmbiguousBuiltinCallName — an unqualified call names both a builtin and a function of the calling module; the module's function is called as module@name (also from inside that module), a builtin is always called unqualified
- E2090 SupervisorTraitShape — Supervisor or FailureReporter trait/impl shape error: required methods (init; region_dump_limit, handle_report), parameter and return types (spec 15.4.13)
- E2091 ActorOperationPlacement — spawn_linked, link, monitor, demonitor, child_table_first_ref, kill_abnormal, stop_self and fail_self calls only inside an actor behavior; wait_for_exit only inside main/0; spawn_linked is no longer public; add_child parent must be a Supervisor actor_ref
- E2092 SupervisorInitSignature — Supervisor impl must declare init/1 with one ActorState parameter (spec 15.4.13.1)
- E2093 InvalidChildSpecAgentType — child_spec agent_type must be a literal :worker or :supervisor
- E2094 InvalidChildSpecFlavor — child_spec flavor must be a literal :plain or :dangerous; :dangerous requires an id starting with :dangerous_
- E2095 DangerousChildNeedsCastBehavior — a :dangerous child_spec requires a cast-type behavior returning (:no_reply, State)
- E2100 ExternalDangerTaintInProduced — external_danger-touched data appears in the produced value of a sequence proc[external_danger]
- E2101 ExternalDangerRegionInMessage — external_danger regions in an ordinary call reply or cast payload; only FFI result casts are permitted
- E2102 ExternalDangerRegionEscape — external_danger regions move out of the FFI worker behavior
- E2103 ExternalDangerInEffectfulSequence — external_danger-touched data used inside sequence blocks that declare device_io, network_io, hot_swap or register_rwr (spec 7.3)
- E2110 RawForeignStringBinding — raw foreign c_wrapper bindings use Silica string arguments or return one; use pointer-plus-length
- E2111 ForeignTooManyArguments — foreign c_wrapper declaration has more than eight Silica-level arguments after lowering
- E2112 ForeignDisallowedReturnType — foreign c_wrapper declaration uses a disallowed Silica-facing return type
- E2113 SidecarResultShapeMismatch — sidecar result kind (scalar, tagged_result, struct) does not match the foreign return type
- E2114 AdapterStringBindingMismatch — adapter wrapper with string parameter or result requires a raw binding with pointer-plus-length fields
- E2201 DuplicateDeviceDescription — a second device description for one device tag
- E2202 MalformedDeviceDescription — device description body must be a single list literal of literal register records
- E2203 DuplicateRegisterName — device description lists a register twice
- E2204 InvalidRegisterWidth — register width must be 8, 16, 32 or 64
- E2205 MisalignedRegisterOffset — register offset is not a multiple of its width in bytes
- E2206 OverlappingRegisters — two registers in a device description overlap
- E2207 InvalidRegisterAccess — register access must be :read_write, :read_only, :write_only or :write_one_to_clear
- E2208 EmptyDeviceDescription — device description lists no registers
- E2209 NoVisibleDeviceDescription — no device description is visible from this module for the tag
- E2210 RegistersImplOutsideDeviceModule — `impl fn registers(device: ...)` may only appear in a device_* module
- E2211 PokeMissingWidthMarker — poke's value requires a width marker (impl Register8|16|32|64 {})
- E2212 WidthMarkerTypeMismatch — an expression marked impl RegisterN {} has a type that differs from the expected type
- E2213 DeviceTagOrRegisterUnknown — map_device's first argument is not a device tag, or a register is not in the device description
- E2214 PokeWidthMismatch — register width differs from the poke width marker
- E2215 PokeReadOnlyRegister — poke to a :read_only register
- E2216 DevicePrimOutsideDeviceModule — map_device, peek or poke used outside a device_* module
- E2217 DevicePrimNameDefined — a device_* module defines a function named after a device prim
- E2219 DevicePrimInMain — device access (map_device, peek, poke) appears in main
- E2220 PrimNotCompilableForTarget — a device prim cannot be compiled for this target
- E2223 SpawnStartsDeviceCode — spawn or spawn_registered starts a behavior that uses register_rwr or device prims; use spawn_device
- E2224 SpawnDeviceStartsDangerousCode — spawn_device starts a behavior that uses external_danger or dangerous_* code
- E2225 MessageTargetIsDeviceActor — cast, call or send targets a device_actor_ref; use cast_device
- E2230 DeviceUserNeedsDevicePrefix — a module that uses a device_* module must use the device_ prefix in its own name
- E2231 DeviceAndDangerousDependency — a dangerous_* module uses a device_* module (or the reverse)
- E2232 DeviceSurfaceOutsideDeviceModule — spawn_device, cast_device, device_actor_ref, device_window or register_rwr outside a device_* module
- E2233 CastRegisteredDeviceName — cast_registered with a :device_ registry name; use cast_device_registered
- E2235 DuplicateChildId — a child_spec id appears twice in one supervisor's init child list (§20.3.1); reported at the second occurrence
- E2236 StartBeforeFailureReporter — main can start an actor or supervisor (directly or through a called function) before register_failure_reporter runs; the reporter's own spawn is exempt (§15.4.13.4)
- E2237 CastToCallOnlyActor — a cast (cast, cast_registered, send_after, cast_device, register_failure_reporter) reaches an actor whose behaviour returns (:reply, ...), wherever the compiler can follow the reference: variables, function parameters and results, tuple and record fields, list elements, actor state and message fields (§16.1.2, §16.2.6.3, §16.2.6.4)
- E2238 CallToCastOnlyActor — a call (call, call_with_timeout, call_registered) reaches an actor whose behaviour returns (:no_reply, ...), followed the same way as E2237 (§16.1.1, §16.2.6.2, §16.2.6.4)
- E2239 BoardPackDeviceDescribed — a program describes a board-pack device: `impl fn registers(device: (:tag))` whose tag the target's board pack describes, in any module other than the pack's own description module for that tag, whatever the body says (device spec §4.9 rule 5, §4.9.1)
- E2240 CallToSelf — `call()` whose target is `self()` or a name bound from `self()`: the actor would wait for its own reply and deadlock; use `cast(self(), ...)` (spec §16.2.6.5)
- E2241 TerminateSelfByRemoveOrKill — `remove_actor` or `kill_abnormal` whose target is `self()` or a name bound from `self()`; an actor ends itself only with `stop_self` or `fail_self`, and a target the compiler cannot see is still a run-time `:language_error` (spec §15.1.2.3)
- E2313 BufferLengthMismatch — `alloc_buf`'s literal element count differs from the literal N of the `buf(R, Space, T, N)` type it is bound to (spec §12.3.3); reported at the size argument
- E2314 BufferIndexOutOfRange — a literal index of `read_buf`, `buf_load`, `write_buf` or `buf_store` is outside 0..N-1 for a `buf` type with a literal N (spec §12.3.3); reported at the index argument

### Effect checker (E3000-E3999)
- E3000 EffectErrorDefault — effect failure with no code of its own
- E3001 EffectNotDeclaredInSignature — a function uses an effect it does not declare in its signature, or uses effectful code outside a sequence block
- E3002 EffectNotDeclaredInCaller — an effect needed by a callee is not declared in the caller
- E3005 UndeclaredEffect — use of an effect that is not declared
- E3007 InvalidEffectParameter — invalid parameter on an effect alias or user-defined effect
- E3009 ProcOnFunctionReturnType — proc[...] is only allowed on sequence clauses, not on function return types
- E3010 UnusedEffectDeclaration — a sequence block declares an effect that none of its calls requires
- E3011 ListMemorySpaceMismatch — a List type or list primitive uses a memory space different from the sequence's mem(...)
- E3012 NestedExternalDanger — sequence proc[external_danger] is valid only as the root body of a function

### SIR generator (E4000-E4049)
- E4001 UnloweredBuiltinCall — internal: a call the type checker accepted as a builtin (spec 5) that the SIR generator did not lower; reported at the function's declaration instead of an unresolved symbol at link time

### Module and FFI checks (emitted in the E4000-E4049 range)
- E4005 UseAfterFunction — `use` must appear before function definitions (spec 19.3.1)
- E4006 ModuleNameMismatch — module declaration does not match the file's module name (spec 19.1)
- E4007 DuplicateModuleDeclaration — duplicate module declaration in a file (spec 19.1)
- E4008 SelfImport — a module cannot import itself (spec 19.4)
- E4009 DuplicateUse — a module name appears twice in one file's `use` declarations (`use alpha; use alpha;` or `use alpha, alpha;`), reported at the second occurrence (spec 19.3.1)
- E4010 ExportTargetMissing — exported function not found or arity mismatch; also internal: missing export target (spec 19.2.1)
- E4011 FunctionShadowsImport — a function shadows an imported or earlier definition (spec 19.3.2)
- E4012 DuplicateModuleName — two different files in one build share a module name; reported by the driver before compilation, naming both files (spec 19.3.1)
- E4013 DuplicateExport — duplicate export in a module (spec 19.2.2)
- E4014 InvalidExportArity — invalid export arity; must be a non-negative decimal (spec 19.2)
- E4015 DuplicateFunctionDefinition — duplicate function definition with the same arity
- E4016 ModuleHasNoEntryOrExport — a module must define main/0, export at least one function, or export a trait (spec 19.1)
- E4017 ExportTraitNameMismatch — export trait name must match the module (file) name (spec 3.4.8)
- E4018 MultipleExportTraits — only one export trait declaration per module
- E4020 DangerousPrefixRequired — modules that declare or expose foreign functions must use the dangerous_ prefix
- E4021 DangerousImporterPrefix — a module that imports or uses a dangerous_* module must use the dangerous_ prefix
- E4022 RawForeignExported — raw foreign c_wrapper bindings must not be exported to application code (spec 3.3)
- E4023 ForeignBindingMissingMeta — foreign c_wrapper bindings need wrapper_meta paths or a meta path
- E4024 MetaPathOutsideDangerousSource — wrapper_meta and meta paths must be under dangerous_exposure_source at the project root
- E4025 DangerousExportNotAdapter — an exported function from a dangerous_* module must be a Silica adapter wrapper with a body (spec 3.3)
- E4026 DangerousSpawnSurfaceOutsideDangerousModule — spawn_dangerous, spawn_dangerous_registered or dangerous_actor_ref outside a dangerous_* module
- E4030 SidecarFileNotFound — sidecar file not found (spec 13.1)
- E4031 SidecarSymbolNotFound — no wrapper entry for a foreign symbol in the sidecar, or no sidecar path available for it
- E4032 SidecarMissingLinkLibrary — sidecar file is missing link_library (spec 13.2)
- E4033 SidecarWrapperIncomplete — sidecar wrapper entry is missing required result or error_domain fields (spec 13.2)
- E4034 PrebuiltArchiveNotFound — prebuilt library archive not found (spec 14.2)
- E4040 ForeignWorkNeedsCastOnlyBehavior — actors that initiate foreign work must use cast-only behaviors (spec 4.3)
- E4041 ExternalDangerMisplaced — external_danger sequence blocks are only valid directly inside the cast-only behavior installed by spawn_dangerous (spec 4.6)
- E4042 DangerousCallMisplaced — calls to dangerous_* functions must be in the sequence portion of sequence proc[external_danger] inside an FFI worker behavior (spec 4.5)
- E4043 SpawnRegisteredDangerousName — spawn_registered of a dangerous behavior must use spawn_dangerous_registered and a :dangerous_ atom (spec 4.7)
- E4044 SpawnStartsDangerousCode — spawn starts a behavior that uses external_danger or dangerous_* code; use spawn_dangerous
- E4045 SpawnDangerousWithoutDangerousCode — spawn_dangerous requires a behavior that uses sequence proc[external_danger] or dangerous_* code
- E4046 SpawnDangerousRegisteredAtom — spawn_dangerous_registered requires a registration atom beginning with :dangerous_
- E4047 SpawnDangerousDeclaresExternalDanger — a sequence that calls spawn_dangerous must not declare external_danger (spec 4.4)
- E4048 CastRegisteredDangerousName — cast_registered with a :dangerous_ registry name; use cast_dangerous_registered (spec 4.9)
- E4049 CastDangerousRegisteredAtom — cast_dangerous_registered requires a registration atom beginning with :dangerous_ (spec 4.9)

### Emitter (E4050-E4099)
- No codes emitted.

### Warnings (W-codes; the compile succeeds)
- W2201 DeviceWriteOneToClearWriteBack — in a device_* module, `poke(w, :r, v)` writes back the unmodified value just read by `v <- peek(w, :r)` from the same `:write_one_to_clear` register, which clears every bit that was set (device spec §4.9); printed as a `DeviceWarning` at the poke
- W4001 FFI_Warning — a module declares an FFI wrapper function (a declaration of tag 9 with a foreign-symbol body); one warning per wrapper, printed at the declaration as `DANGER DANGER DANGER: this module uses FFI wrapper '<name>' for foreign symbol '<symbol>'. FFI breaks the Silica security model for this app and exposes the entire application to memory insecurity, ABI unsafety, undefined behavior, privilege-boundary collapse, and other security issues from the foreign code and wrapper boundary.` (module checker, section 3); the compile succeeds

### Notes
- E1009-E1011 are emitted by the module checker and E2090-E2241 by the type checker's supervisor, external_danger, FFI and device checks; they sit in the E1xxx/E2xxx ranges as allocated. E4005-E4049 (module, FFI and dangerous-spawn checks) are emitted by the module and type checkers inside the E4000-E4049 range; only E4001 comes from the SIR generator.
- E2003, E2005 and E2010 are broad: they cover many messages at many sites (see the descriptions above).

## Retired names (never emitted)

Names that earlier versions of this registry listed but the compiler never emitted. They are kept for history and are not reassigned.

- E0000 LexerErrorDefault — never emitted. E0001-E0006 now carry the meanings this entry once listed beside it (InvalidIntegerLiteral widened to InvalidNumericLiteral), and E0007 is InvalidUtf8 (2026-10-16)
- E1001 ExpectedToken — the code is now used as a driver fallback (ParseFailureNoCode)
- E1002-E1008 NestedFunctionDeclaration, ExpectedIdentifier, ExpectedType, ExpectedExpression, ExpectedMemorySpace, WildcardRequiresTypeAnnotation, UnsupportedSyntax
- E2002 UndefinedType — code now UndefinedIdentifier
- E2004 VariableShadowing — code now UnknownOperator
- E2005 TupleArityMismatch — code now InvalidCaseOrBuiltinShape
- E2006 RecordFieldCountMismatch — code now InvalidTypeUse
- E2007 RecordFieldTypeMismatch — code now UnknownFunction
- E2008 FunctionReturnTypeMismatch — code now CaseMissingCatchAllArm
- E2009 MissingTraitImplementation — code now SumRecordVariantFieldTypeConflict
- E2010 TypeInferenceNotImplemented — code now InvalidMemoryRegionType
- E2011 FunctionLiteralMissingEffectDeclaration — code now IntegerLiteralOutOfRange
- E3001 MissingEffectCapability — code now EffectNotDeclaredInSignature
- E3002 EffectNotActive — code now EffectNotDeclaredInCaller
- E3003 EffectCompatibilityMismatch
- E3004 EffectPushFailure
- E4000 SIR default
- E4050 Emitter default
- E2234 was removed and is not used.

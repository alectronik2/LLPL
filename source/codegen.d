module codegen;

import std.stdio;
import std.string;
import std.format;
import std.conv;
import std.array;
import std.algorithm;
import std.range;
import ast;
import errors;

class CodeGenerator {
    private int indentLevel;
    private string[] deferredStatements;
    private int tempVarCounter;
    private string currentClassName;
    private string currentModulePath; // Module whose code is currently being generated, for error citations
    private string[] currentNamespaceSegments; // Enclosing namespace path of the declaration being generated
    private Type[string] variableTypes; // Maps variable names to their types
    private bool[string] constVariables; // Names (mangled) of `const`-declared variables
    private FunctionDecl[string] functionRegistry; // Functions, by mangled (namespace-prefixed) name
    private ClassDecl[string] classRegistry; // Classes, by mangled (namespace-prefixed) name
    private StructDecl[string] structRegistry; // Structs, by mangled (namespace-prefixed) name

    this() {
        indentLevel = 0;
        tempVarCounter = 0;
    }

    private string indent() {
        string result = "";
        for (int i = 0; i < indentLevel; i++) {
            result ~= "    ";
        }
        return result;
    }

    // Escapes a decoded LLPL string (already past lexer escape processing,
    // e.g. \x1b is a real ESC byte by this point) back into a C string
    // literal body: named escapes for the common control characters, and
    // \ooo (octal) for any other non-printable byte, so the generated C
    // source never contains raw control characters. Octal, not \xHH: C's
    // hex escapes are unbounded-width and would greedily swallow a
    // following character that happens to look like a hex digit (e.g.
    // "\x1bA" is one escape, not ESC followed by 'A'); \ooo is always
    // exactly 3 digits, so nothing after it can be misread as part of it.
    private string escapeCString(string s) {
        string result = "";
        foreach (c; s) {
            switch (c) {
                case '\\': result ~= "\\\\"; break;
                case '"': result ~= "\\\""; break;
                case '\n': result ~= "\\n"; break;
                case '\t': result ~= "\\t"; break;
                case '\r': result ~= "\\r"; break;
                default:
                    if (c < 0x20 || c == 0x7f) {
                        result ~= format("\\%03o", cast(int)cast(ubyte)c);
                    } else {
                        result ~= c;
                    }
                    break;
            }
        }
        return result;
    }

    string generate(Program program) {
        return generateMultiple([program]);
    }

    // Joins namespace path segments into a declaration's mangled C identifier,
    // e.g. mangled(["Graphics"], "Point") -> "Graphics_Point".
    private string mangled(string[] segments, string name) {
        return segments.length > 0 ? segments.join("_") ~ "_" ~ name : name;
    }

    private string mangledFunc(FunctionDecl fn) {
        // extern functions bind to a real external C symbol by that exact
        // name, regardless of namespace nesting - never mangle those.
        if (fn.isExtern) return fn.name;
        return mangled(fn.namespaceSegments, fn.name);
    }

    private string mangledClass(ClassDecl cls) {
        return mangled(cls.namespaceSegments, cls.name);
    }

    private string mangledStruct(StructDecl st) {
        return mangled(st.namespaceSegments, st.name);
    }

    // Recursively hoists the contents of `namespace` blocks to the top level,
    // stamping each contained function/class/struct/global with the full
    // chain of enclosing namespace names (innermost last).
    private ASTNode[] flattenNamespaces(ASTNode[] decls, string[] segments) {
        ASTNode[] result;
        foreach (decl; decls) {
            if (auto ns = cast(NamespaceDecl)decl) {
                result ~= flattenNamespaces(ns.declarations, segments ~ ns.name);
            } else if (auto funcDecl = cast(FunctionDecl)decl) {
                funcDecl.namespaceSegments = segments;
                result ~= funcDecl;
            } else if (auto classDecl = cast(ClassDecl)decl) {
                classDecl.namespaceSegments = segments;
                result ~= classDecl;
            } else if (auto structDecl = cast(StructDecl)decl) {
                structDecl.namespaceSegments = segments;
                result ~= structDecl;
            } else if (auto varDecl = cast(VarDecl)decl) {
                varDecl.namespaceSegments = segments;
                result ~= varDecl;
            } else if (auto aliasDecl = cast(AliasDecl)decl) {
                aliasDecl.namespaceSegments = segments;
                result ~= aliasDecl;
            } else {
                result ~= decl;
            }
        }
        return result;
    }

    string generateMultiple(Program[] programs) {
        string code = "";

        // Resolve namespace blocks into flat, mangled top-level declarations
        // before anything else looks at prog.declarations.
        foreach (prog; programs) {
            prog.declarations = flattenNamespaces(prog.declarations, []);
        }

        // Register functions, classes and structs from all modules up front so
        // type inference can resolve calls/fields regardless of declaration order.
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    functionRegistry[mangledFunc(funcDecl)] = funcDecl;
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    classRegistry[mangledClass(classDecl)] = classDecl;
                } else if (auto structDecl = cast(StructDecl)decl) {
                    structRegistry[mangledStruct(structDecl)] = structDecl;
                }
            }
        }

        // Resolve any inferred class/struct field types before they can be
        // looked up. currentModulePath/currentNamespacePath are set per-decl
        // so inference errors cite the right file and unqualified sibling
        // lookups (if the initializer ever needs one) resolve correctly.
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            foreach (decl; prog.declarations) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    currentNamespaceSegments = classDecl.namespaceSegments;
                    foreach (field; classDecl.fields) {
                        if (field.type is null) {
                            field.type = inferType(field.initializer);
                        }
                        resolveType(field.type);
                        if (field.bitWidth >= 0) {
                            checkBitfield(field);
                        }
                    }
                } else if (auto structDecl = cast(StructDecl)decl) {
                    currentNamespaceSegments = structDecl.namespaceSegments;
                    foreach (field; structDecl.fields) {
                        if (field.type is null) {
                            field.type = inferType(field.initializer);
                        }
                        resolveType(field.type);
                        if (field.bitWidth >= 0) {
                            checkBitfield(field);
                        }
                    }
                }
            }
        }

        // Include runtime header
        code ~= "#include <stdint.h>\n";
        code ~= "#include <stddef.h>\n";
        code ~= "#include \"runtime.h\"\n\n";

        // Forward declarations for classes and structs from all modules
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    string cName = mangledClass(classDecl);
                    code ~= format("typedef struct %s %s;\n", cName, cName);
                } else if (auto structDecl = cast(StructDecl)decl) {
                    string sName = mangledStruct(structDecl);
                    code ~= format("typedef struct %s %s;\n", sName, sName);
                }
            }
        }
        code ~= "\n";

        // Forward declarations for functions and methods from all modules.
        // currentNamespaceSegments is set per-declaration so resolveType
        // resolves unqualified namespaced types exactly the way the real
        // definition will, keeping each forward declaration's signature
        // consistent with the definition that follows it later.
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    currentNamespaceSegments = funcDecl.namespaceSegments;
                    if (funcDecl.isExtern) {
                        string params = "";
                        foreach (i, param; funcDecl.params) {
                            if (i > 0) params ~= ", ";
                            params ~= format("%s %s", typeToC(param.type), param.name);
                        }
                        if (funcDecl.isVariadic) params ~= ", ...";
                        code ~= format("extern %s %s(%s);\n",
                            typeToC(funcDecl.returnType), mangledFunc(funcDecl), params);
                    } else if (funcDecl.isInterrupt) {
                        string params = "void* __frame";
                        if (funcDecl.params.length >= 1) {
                            resolveType(funcDecl.params[0].type);
                            params ~= format(", %s %s",
                                typeToC(funcDecl.params[0].type), funcDecl.params[0].name);
                        }
                        code ~= format("__attribute__((interrupt)) void %s(%s);\n",
                            mangledFunc(funcDecl), params);
                    } else {
                        resolveType(funcDecl.returnType);
                        string params = "";
                        foreach (i, param; funcDecl.params) {
                            resolveType(param.type);
                            if (i > 0) params ~= ", ";
                            params ~= format("%s %s", typeToC(param.type), param.name);
                        }
                        if (funcDecl.isVariadic) params ~= ", ...";
                        code ~= format("%s %s(%s);\n",
                            typeToC(funcDecl.returnType), mangledFunc(funcDecl), params);
                    }
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    currentNamespaceSegments = classDecl.namespaceSegments;
                    string cName = mangledClass(classDecl);
                    // Constructor forward declaration
                    if (classDecl.constructor) {
                        string params = "";
                        foreach (i, param; classDecl.constructor.params) {
                            resolveType(param.type);
                            if (i > 0) params ~= ", ";
                            params ~= format("%s %s", typeToC(param.type), param.name);
                        }
                        code ~= format("%s* %s_new(%s);\n", cName, cName, params);
                    }

                    // Destructor forward declaration
                    if (classDecl.destructor) {
                        code ~= format("void %s_destroy(void* ptr);\n", cName);
                    }

                    // Method forward declarations
                    foreach (method; classDecl.methods) {
                        resolveType(method.returnType);
                        string params = format("%s* self", cName);
                        foreach (param; method.params) {
                            resolveType(param.type);
                            params ~= format(", %s %s", typeToC(param.type), param.name);
                        }
                        code ~= format("%s %s_%s(%s);\n",
                            typeToC(method.returnType), cName, method.name, params);
                    }
                }
            }
        }
        code ~= "\n";

        // Generate declarations from all modules (skip import statements)
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            if (prog.modulePath.length > 0) {
                code ~= format("// Module: %s\n", prog.modulePath);
            }
            foreach (decl; prog.declarations) {
                if (cast(ImportStmt)decl) {
                    continue;  // Skip import statements in code generation
                }
                code ~= generateDeclaration(decl);
                code ~= "\n";
            }
        }

        return code;
    }

    private string generateDeclaration(ASTNode node) {
        if (auto funcDecl = cast(FunctionDecl)node) {
            return generateFunction(funcDecl);
        } else if (auto classDecl = cast(ClassDecl)node) {
            return generateClass(classDecl);
        } else if (auto structDecl = cast(StructDecl)node) {
            return generateStruct(structDecl);
        } else if (auto varDecl = cast(VarDecl)node) {
            return generateGlobalVar(varDecl);
        } else if (auto aliasDecl = cast(AliasDecl)node) {
            return generateAlias(aliasDecl);
        }
        return "";
    }

    private bool isKnownSymbol(string name) {
        return (name in functionRegistry) !is null || (name in classRegistry) !is null ||
               (name in structRegistry) !is null || (name in variableTypes) !is null;
    }

    // Resolves `alias name = a.b.c`'s target path to the mangled C
    // identifier it refers to, using the same resolution order as every
    // other namespace-qualified reference: exact mangled match, then each
    // enclosing namespace scope, then (for extern functions specifically,
    // which are never mangled) the bare rightmost segment.
    private string resolveAliasTarget(string[] path, int line, int column) {
        string flat = path.join("_");
        if (isKnownSymbol(flat)) return flat;

        foreach (candidate; enclosingQualifications(flat)) {
            if (isKnownSymbol(candidate)) return candidate;
        }

        string rightmost = path[$ - 1];
        if (auto fd = rightmost in functionRegistry) {
            if (fd.isExtern) return rightmost;
        }

        throw new CompileError(format("Cannot resolve alias target '%s'", path.join(".")),
            currentModulePath, line, column);
    }

    private string generateAlias(AliasDecl aliasDecl) {
        currentNamespaceSegments = aliasDecl.namespaceSegments;
        string mangledName = mangled(aliasDecl.namespaceSegments, aliasDecl.name);

        if (isKnownSymbol(mangledName)) {
            throw new CompileError(
                format("Cannot declare alias '%s': a symbol with that name already exists",
                    aliasDecl.name),
                currentModulePath, aliasDecl.line, aliasDecl.column);
        }

        string target = resolveAliasTarget(aliasDecl.targetPath, aliasDecl.line, aliasDecl.column);

        // Register the alias so later references to it resolve exactly like
        // the thing it points to (correct arity/variadic-ness for calls,
        // correct field/method lookup for types, etc.) - generateExpression
        // will emit the alias name literally, and the #define below is what
        // actually makes that resolve to the real symbol in the C output.
        if (auto fd = target in functionRegistry) functionRegistry[mangledName] = *fd;
        if (auto cd = target in classRegistry) classRegistry[mangledName] = *cd;
        if (auto sd = target in structRegistry) structRegistry[mangledName] = *sd;
        if (auto vt = target in variableTypes) variableTypes[mangledName] = *vt;

        return format("#define %s %s\n", mangledName, target);
    }

    private string generateStruct(StructDecl structDecl) {
        string sName = mangledStruct(structDecl);
        currentNamespaceSegments = structDecl.namespaceSegments;

        string attr = structDecl.packed ? " __attribute__((packed))" : "";
        string code = format("struct%s %s {\n", attr, sName);
        foreach (field; structDecl.fields) {
            if (field.bitWidth >= 0) {
                code ~= format("    %s %s : %d;\n", typeToC(field.type), field.name, field.bitWidth);
            } else {
                code ~= format("    %s %s;\n", typeToC(field.type), field.name);
            }
        }
        code ~= "};\n";
        return code;
    }

    private string generateGlobalVar(VarDecl varDecl) {
        currentNamespaceSegments = varDecl.namespaceSegments;
        if (varDecl.bitWidth >= 0) {
            throw new CompileError("Bit-fields are only allowed on class fields, not global variables",
                currentModulePath, varDecl.line, varDecl.column);
        }
        if (varDecl.type is null) {
            varDecl.type = inferType(varDecl.initializer);
        }
        resolveType(varDecl.type);
        string cName = mangled(varDecl.namespaceSegments, varDecl.name);
        variableTypes[cName] = varDecl.type;
        if (varDecl.isConst) {
            constVariables[cName] = true;
        }

        // Handle array declarations specially
        string constPrefix = varDecl.isConst ? "const " : "";
        string code;
        if (varDecl.type.isArray && varDecl.type.arraySize > 0) {
            string baseType = primitiveToC(varDecl.type.name);
            if (varDecl.type.isPointer) baseType ~= "*";
            code = format("%s%s %s[%d]", constPrefix, baseType, cName, varDecl.type.arraySize);
        } else {
            code = format("%s%s %s", constPrefix, typeToC(varDecl.type), cName);
        }

        if (varDecl.initializer) {
            code ~= " = " ~ generateExpression(varDecl.initializer);
        }
        code ~= ";\n";
        return code;
    }

    private string generateClass(ClassDecl classDecl) {
        string cName = mangledClass(classDecl);
        currentClassName = cName;
        currentNamespaceSegments = classDecl.namespaceSegments;
        string code = "";

        // Generate struct definition
        code ~= format("struct %s {\n", cName);
        code ~= "    RefCount ref_count;\n";
        foreach (field; classDecl.fields) {
            if (field.bitWidth >= 0) {
                code ~= format("    %s %s : %d;\n", typeToC(field.type), field.name, field.bitWidth);
            } else {
                code ~= format("    %s %s;\n", typeToC(field.type), field.name);
            }
        }
        code ~= "};\n\n";

        // Generate constructor
        if (classDecl.constructor) {
            code ~= generateConstructor(classDecl, classDecl.constructor);
        }

        // Generate destructor
        if (classDecl.destructor) {
            code ~= generateDestructor(classDecl, classDecl.destructor);
        }

        // Generate methods
        foreach (method; classDecl.methods) {
            code ~= generateMethod(classDecl, method);
        }

        currentClassName = "";
        return code;
    }

    private string generateConstructor(ClassDecl classDecl, FunctionDecl constructor) {
        string cName = mangledClass(classDecl);
        string code = "";
        string params = "";

        // Set current class/namespace context
        string prevClassName = currentClassName;
        currentClassName = cName;
        currentNamespaceSegments = classDecl.namespaceSegments;
        variableTypes["self"] = new Type(cName);

        foreach (i, param; constructor.params) {
            resolveType(param.type);
            if (i > 0) params ~= ", ";
            params ~= format("%s %s", typeToC(param.type), param.name);
            variableTypes[param.name] = param.type;
        }

        code ~= format("%s* %s_new(%s) {\n", cName, cName, params);
        indentLevel++;
        code ~= indent() ~ format("%s* self = (%s*)rc_alloc(sizeof(%s));\n",
            cName, cName, cName);
        code ~= indent() ~ "if (!self) return NULL;\n";
        code ~= indent() ~ "rc_init(&self->ref_count);\n\n";

        // Generate constructor body
        if (constructor.body_) {
            foreach (stmt; constructor.body_.statements) {
                code ~= generateStatement(stmt, false);
            }
        }

        code ~= indent() ~ "return self;\n";
        indentLevel--;
        code ~= "}\n\n";

        // Restore previous context
        currentClassName = prevClassName;

        return code;
    }

    private string generateDestructor(ClassDecl classDecl, FunctionDecl destructor) {
        string cName = mangledClass(classDecl);
        currentNamespaceSegments = classDecl.namespaceSegments;
        string code = "";

        code ~= format("void %s_destroy(void* ptr) {\n", cName);
        indentLevel++;
        code ~= indent() ~ format("%s* self = (%s*)ptr;\n", cName, cName);

        // Generate destructor body
        if (destructor.body_) {
            foreach (stmt; destructor.body_.statements) {
                code ~= generateStatement(stmt, false);
            }
        }

        // Release reference-counted fields
        foreach (field; classDecl.fields) {
            if (!isPrimitiveTypeName(field.type.name) && !field.type.isPointer) {
                code ~= indent() ~ format("if (self->%s) rc_release(self->%s, %s_destroy);\n",
                    field.name, field.name, field.type.name);
            }
        }

        indentLevel--;
        code ~= "}\n\n";

        return code;
    }

    private string generateMethod(ClassDecl classDecl, FunctionDecl method) {
        string cName = mangledClass(classDecl);
        string code = "";
        string params = format("%s* self", cName);

        // Set current class/namespace context
        string prevClassName = currentClassName;
        currentClassName = cName;
        currentNamespaceSegments = classDecl.namespaceSegments;
        variableTypes["self"] = new Type(cName);

        resolveType(method.returnType);
        foreach (param; method.params) {
            resolveType(param.type);
            params ~= format(", %s %s", typeToC(param.type), param.name);
            variableTypes[param.name] = param.type;
        }

        code ~= format("%s %s_%s(%s) {\n",
            typeToC(method.returnType), cName, method.name, params);
        indentLevel++;

        deferredStatements = [];

        if (method.body_) {
            foreach (stmt; method.body_.statements) {
                code ~= generateStatement(stmt, false);
            }
        }

        // Add deferred statements before return
        if (deferredStatements.length > 0) {
            foreach_reverse (deferStmt; deferredStatements) {
                code ~= deferStmt;
            }
        }

        indentLevel--;
        code ~= "}\n\n";

        // Restore previous context
        currentClassName = prevClassName;

        return code;
    }

    private string generateFunction(FunctionDecl funcDecl) {
        if (funcDecl.isExtern) {
            // Just a forward declaration
            string params = "";
            foreach (i, param; funcDecl.params) {
                if (i > 0) params ~= ", ";
                params ~= format("%s %s", typeToC(param.type), param.name);
            }
            if (funcDecl.isVariadic) params ~= ", ...";
            return format("extern %s %s(%s);\n",
                typeToC(funcDecl.returnType), mangledFunc(funcDecl), params);
        }

        if (funcDecl.isInterrupt) {
            return generateInterruptFunction(funcDecl);
        }

        string code = "";
        string params = "";
        currentNamespaceSegments = funcDecl.namespaceSegments;
        resolveType(funcDecl.returnType);

        foreach (i, param; funcDecl.params) {
            resolveType(param.type);
            if (i > 0) params ~= ", ";
            params ~= format("%s %s", typeToC(param.type), param.name);
            variableTypes[param.name] = param.type;
        }
        if (funcDecl.isVariadic) params ~= ", ...";

        code ~= format("%s %s(%s) {\n",
            typeToC(funcDecl.returnType), mangledFunc(funcDecl), params);
        indentLevel++;

        deferredStatements = [];

        if (funcDecl.body_) {
            foreach (stmt; funcDecl.body_.statements) {
                code ~= generateStatement(stmt, false);
            }
        }

        indentLevel--;
        code ~= "}\n";

        return code;
    }

    // `interrupt func handler(...)` compiles to a GCC hardware-interrupt
    // handler: __attribute__((interrupt)) with the mandatory leading frame
    // pointer, and (for exceptions that push one) a trailing error-code
    // parameter driven by whether the LLPL declaration has a parameter.
    private string generateInterruptFunction(FunctionDecl funcDecl) {
        if (funcDecl.returnType.name != "void") {
            throw new CompileError("Interrupt functions must return void",
                currentModulePath, funcDecl.line, funcDecl.column);
        }
        if (funcDecl.params.length > 1) {
            throw new CompileError(
                "Interrupt functions take at most one parameter (the hardware error code)",
                currentModulePath, funcDecl.line, funcDecl.column);
        }

        currentNamespaceSegments = funcDecl.namespaceSegments;

        string params = "void* __frame";
        if (funcDecl.params.length == 1) {
            Parameter param = funcDecl.params[0];
            resolveType(param.type);
            params ~= format(", %s %s", typeToC(param.type), param.name);
            variableTypes[param.name] = param.type;
        }

        string code = format("__attribute__((interrupt)) void %s(%s) {\n", mangledFunc(funcDecl), params);
        indentLevel++;

        deferredStatements = [];

        if (funcDecl.body_) {
            foreach (stmt; funcDecl.body_.statements) {
                code ~= generateStatement(stmt, false);
            }
        }

        indentLevel--;
        code ~= "}\n";

        return code;
    }

    private string generateStatement(ASTNode node, bool isDeferred) {
        string code = "";

        if (auto varDecl = cast(VarDecl)node) {
            if (varDecl.bitWidth >= 0) {
                throw new CompileError("Bit-fields are only allowed on class fields, not local variables",
                    currentModulePath, varDecl.line, varDecl.column);
            }

            // Infer the type from the initializer if none was declared
            if (varDecl.type is null) {
                varDecl.type = inferType(varDecl.initializer);
            }
            resolveType(varDecl.type);

            // Track the variable type
            variableTypes[varDecl.name] = varDecl.type;
            if (varDecl.isConst) {
                constVariables[varDecl.name] = true;
            }

            // Handle array declarations specially
            string constPrefix = varDecl.isConst ? "const " : "";
            if (varDecl.type.isArray && varDecl.type.arraySize > 0) {
                string baseType = primitiveToC(varDecl.type.name);
                if (varDecl.type.isPointer) baseType ~= "*";
                code ~= indent() ~ format("%s%s %s[%d]", constPrefix, baseType, varDecl.name, varDecl.type.arraySize);
            } else {
                code ~= indent() ~ format("%s%s %s", constPrefix, typeToC(varDecl.type), varDecl.name);
            }

            if (varDecl.initializer) {
                code ~= " = " ~ generateExpression(varDecl.initializer);
            }
            code ~= ";\n";
        } else if (auto ifStmt = cast(IfStmt)node) {
            code ~= indent() ~ "if (" ~ generateExpression(ifStmt.condition) ~ ") {\n";
            indentLevel++;
            foreach (stmt; ifStmt.thenBlock.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
            if (ifStmt.elseBlock) {
                code ~= indent() ~ "} else {\n";
                indentLevel++;
                foreach (stmt; ifStmt.elseBlock.statements) {
                    code ~= generateStatement(stmt, isDeferred);
                }
                indentLevel--;
            }
            code ~= indent() ~ "}\n";
        } else if (auto whileStmt = cast(WhileStmt)node) {
            code ~= indent() ~ "while (" ~ generateExpression(whileStmt.condition) ~ ") {\n";
            indentLevel++;
            foreach (stmt; whileStmt.body_.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
            code ~= indent() ~ "}\n";
        } else if (auto forStmt = cast(ForStmt)node) {
            code ~= indent() ~ "{\n";
            indentLevel++;
            if (forStmt.initializer) {
                code ~= generateStatement(forStmt.initializer, isDeferred);
            }
            code ~= indent() ~ "while (";
            if (forStmt.condition) {
                code ~= generateExpression(forStmt.condition);
            } else {
                code ~= "1";
            }
            code ~= ") {\n";
            indentLevel++;
            foreach (stmt; forStmt.body_.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            if (forStmt.update) {
                code ~= indent() ~ generateExpression(forStmt.update) ~ ";\n";
            }
            indentLevel--;
            code ~= indent() ~ "}\n";
            indentLevel--;
            code ~= indent() ~ "}\n";
        } else if (auto returnStmt = cast(ReturnStmt)node) {
            // Execute deferred statements before return
            if (!isDeferred && deferredStatements.length > 0) {
                foreach_reverse (deferStmt; deferredStatements) {
                    code ~= deferStmt;
                }
            }
            code ~= indent() ~ "return";
            if (returnStmt.value) {
                code ~= " " ~ generateExpression(returnStmt.value);
            }
            code ~= ";\n";
        } else if (auto deferStmt = cast(DeferStmt)node) {
            // Store deferred statement for later
            string deferCode = generateStatement(deferStmt.statement, true);
            deferredStatements ~= deferCode;
        } else if (auto block = cast(Block)node) {
            code ~= indent() ~ "{\n";
            indentLevel++;
            foreach (stmt; block.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
            code ~= indent() ~ "}\n";
        } else if (auto exprStmt = cast(ExprStmt)node) {
            code ~= indent() ~ generateExpression(exprStmt.expression) ~ ";\n";
        } else if (auto asmStmt = cast(AsmStmt)node) {
            code ~= generateAsm(asmStmt);
        } else if (auto matchStmt = cast(MatchStmt)node) {
            code ~= generateMatch(matchStmt, isDeferred);
        }

        return code;
    }

    private string generateAsm(AsmStmt asmStmt) {
        bool hasClobbers = asmStmt.clobbers.length > 0;
        bool hasInputs = asmStmt.inputs.length > 0 || hasClobbers;
        bool hasOutputs = asmStmt.outputs.length > 0 || hasInputs;

        string code = indent() ~ "__asm__ __volatile__ (\n";
        indentLevel++;

        foreach (line; asmStmt.templateLines) {
            code ~= indent() ~ format("\"%s\\n\\t\"\n", escapeCString(line));
        }

        string renderOperands(AsmOperand[] operands) {
            string result = "";
            foreach (i, op; operands) {
                if (i > 0) result ~= ", ";
                result ~= format("\"%s\"(%s)", op.constraint, generateExpression(op.expr));
            }
            return result;
        }

        if (hasOutputs) {
            code ~= indent() ~ ": " ~ renderOperands(asmStmt.outputs) ~ "\n";
        }
        if (hasInputs) {
            code ~= indent() ~ ": " ~ renderOperands(asmStmt.inputs) ~ "\n";
        }
        if (hasClobbers) {
            string clobberList = "";
            foreach (i, c; asmStmt.clobbers) {
                if (i > 0) clobberList ~= ", ";
                clobberList ~= format("\"%s\"", c);
            }
            code ~= indent() ~ ": " ~ clobberList ~ "\n";
        }

        indentLevel--;
        code ~= indent() ~ ");\n";
        return code;
    }

    // Desugars to an if/else-if chain over a temp holding the subject's
    // value, evaluated once. String subjects (char*) compare with strcmp;
    // everything else compares with ==. There's no fallthrough between arms,
    // unlike a C switch.
    private string generateMatch(MatchStmt matchStmt, bool isDeferred) {
        Type subjectType = inferType(matchStmt.subject);
        resolveType(subjectType);
        bool isString = subjectType.isPointer && subjectType.name == "char";

        tempVarCounter++;
        string tmpName = format("__match%d", tempVarCounter);

        string code = indent() ~ "{\n";
        indentLevel++;
        code ~= indent() ~ format("%s %s = %s;\n",
            typeToC(subjectType), tmpName, generateExpression(matchStmt.subject));

        bool first = true;
        Block defaultBody = null;

        foreach (matchCase; matchStmt.cases) {
            if (matchCase.patterns.length == 0) {
                defaultBody = matchCase.body_;
                continue;
            }

            string cond = "";
            foreach (i, pattern; matchCase.patterns) {
                if (i > 0) cond ~= " || ";
                string patternExpr = generateExpression(pattern);
                cond ~= isString
                    ? format("(strcmp(%s, %s) == 0)", tmpName, patternExpr)
                    : format("(%s == %s)", tmpName, patternExpr);
            }

            code ~= indent() ~ format("%s (%s) {\n", first ? "if" : "} else if", cond);
            first = false;
            indentLevel++;
            foreach (stmt; matchCase.body_.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
        }

        if (!first) {
            if (defaultBody) {
                code ~= indent() ~ "} else {\n";
                indentLevel++;
                foreach (stmt; defaultBody.statements) {
                    code ~= generateStatement(stmt, isDeferred);
                }
                indentLevel--;
            }
            code ~= indent() ~ "}\n";
        } else if (defaultBody) {
            code ~= indent() ~ "{\n";
            indentLevel++;
            foreach (stmt; defaultBody.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
            code ~= indent() ~ "}\n";
        }

        indentLevel--;
        code ~= indent() ~ "}\n";
        return code;
    }

    // --- Namespace-qualified name resolution --------------------------------
    //
    // A reference like `Graphics.Utils.helper()` parses as nested MemberExprs
    // rooted at an Identifier, exactly like `obj.method()` instance access.
    // These helpers flatten such a chain into its mangled form so it can be
    // checked against the function/global registries and resolved as a plain
    // call/variable reference instead of instance member access, whenever the
    // root isn't a real local/instance variable.

    private string leftmostName(ASTNode expr) {
        if (auto ident = cast(Identifier)expr) return ident.name;
        if (auto member = cast(MemberExpr)expr) return leftmostName(member.object);
        return "";
    }

    private string flattenPath(ASTNode expr) {
        if (auto ident = cast(Identifier)expr) return ident.name;
        if (auto member = cast(MemberExpr)expr) {
            string base = flattenPath(member.object);
            if (base.length == 0) return "";
            return base ~ "_" ~ member.member;
        }
        return "";
    }

    // Tries each enclosing namespace scope, innermost first (Graphics.Utils,
    // then Graphics, then global), the way unqualified/partially-qualified
    // lookup works inside nested namespaces.
    private string[] enclosingQualifications(string suffix) {
        string[] candidates;
        for (size_t i = currentNamespaceSegments.length; i > 0; i--) {
            candidates ~= currentNamespaceSegments[0 .. i].join("_") ~ "_" ~ suffix;
        }
        return candidates;
    }

    private bool isPrimitiveTypeName(string name) {
        switch (name) {
            case "int": case "uint":
            case "int16": case "uint16":
            case "int32": case "uint32":
            case "char": case "bool": case "void":
                return true;
            default:
                return false;
        }
    }

    // Number of storage bits available for a bit-field of this base type, or
    // -1 if the type can't back a bit-field at all (classes, void, ...).
    private int primitiveBitSize(string name) {
        switch (name) {
            case "int": case "uint": return 64;
            case "int32": case "uint32": return 32;
            case "int16": case "uint16": return 16;
            case "char": return 8;
            case "bool": return 32; // backed by C `int`
            default: return -1;
        }
    }

    private void checkBitfield(VarDecl field) {
        auto err = (string message) =>
            new CompileError(message, currentModulePath, field.line, field.column);

        if (field.type.isPointer || field.type.isArray) {
            throw err(format("Bit-field '%s' cannot be a pointer or array type", field.name));
        }

        int maxBits = primitiveBitSize(field.type.name);
        if (maxBits < 0) {
            throw err(format("Bit-field '%s' must have an integer or bool type, not '%s'",
                field.name, field.type.name));
        }
        if (field.bitWidth == 0) {
            throw err(format("Bit-field '%s' must have a width of at least 1", field.name));
        }
        if (field.bitWidth > maxBits) {
            throw err(format("Bit-field '%s' width %d exceeds the %d bits available in '%s'",
                field.name, field.bitWidth, maxBits, field.type.name));
        }
    }

    // Structs are plain value types with no constructor/allocator; `new`
    // only makes sense for classes.
    private void checkNotStruct(NewExpr newExpr) {
        if (newExpr.type.name in structRegistry) {
            string message = format(
                "Cannot 'new' a struct: '%s' is a value type - declare a variable of that type " ~
                "and assign its fields directly",
                newExpr.type.name);
            throw new CompileError(message, currentModulePath, newExpr.line, newExpr.column);
        }
    }

    // Rejects `x = ...` when `x` (a plain or namespace-qualified variable
    // reference) was declared `const`. Only the variable being assigned is
    // checked - field/index assignment through it (x.field = ...) is fine,
    // since that mutates something the const variable merely points to.
    private void checkNotConstAssignment(ASTNode target) {
        string varName = "";
        if (auto ident = cast(Identifier)target) {
            varName = resolveName(ident.name, (n) => (n in variableTypes) !is null);
        } else if (auto member = cast(MemberExpr)target) {
            varName = tryResolveQualifiedPath(member, (n) => (n in variableTypes) !is null);
        }

        if (varName.length > 0 && (varName in constVariables)) {
            throw new CompileError(
                format("Cannot assign to '%s': it was declared 'const'", varName),
                currentModulePath, target.line, target.column);
        }
    }

    // Resolves a possibly-unqualified class type name to its mangled form
    // in place, the same way resolveName does for functions/variables, so a
    // namespaced class can be referenced unqualified (or partially qualified)
    // from sibling code in that namespace. No-op for primitives or names that
    // are already fully qualified/unresolvable.
    private void resolveType(Type t) {
        if (t is null) return;
        if (isPrimitiveTypeName(t.name)) return;
        if (t.name in classRegistry || t.name in structRegistry) return;
        foreach (candidate; enclosingQualifications(t.name)) {
            if (candidate in classRegistry || candidate in structRegistry) {
                t.name = candidate;
                return;
            }
        }
    }

    private bool isStructTypeName(string name) {
        return (name in structRegistry) !is null;
    }

    private bool isClassTypeName(string name) {
        return (name in classRegistry) !is null;
    }

    // C's default variadic argument promotions only widen types smaller than
    // `int` up to `int` - a bare integer literal or an already-`int`-sized
    // value is passed exactly as-is. Our runtime's va_arg reads every
    // non-pointer vararg as a full 8-byte value (see runtime.c), so anything
    // not already pointer-width needs an explicit cast at the call site;
    // otherwise the callee reads garbage in the upper bits.
    private string variadicPromote(ASTNode arg, string argCode) {
        try {
            Type t = inferType(arg);
            if (t.isPointer || t.isArray || isStructTypeName(t.name) || isClassTypeName(t.name)) {
                return argCode;
            }
            return format("((long long)(%s))", argCode);
        } catch (Exception e) {
            return argCode;
        }
    }

    // Looks up the FunctionDecl a call's callee resolves to, if it's a
    // plain (possibly namespace-qualified) reference to a known function -
    // used to decide which trailing arguments are in a variadic tail.
    private FunctionDecl resolveCalledFunction(ASTNode callee) {
        if (auto ident = cast(Identifier)callee) {
            string resolved = resolveName(ident.name, (n) => (n in functionRegistry) !is null);
            if (auto fd = resolved in functionRegistry) {
                return *fd;
            }
        } else if (auto member = cast(MemberExpr)callee) {
            string qualified = tryResolveQualifiedPath(member, (n) => (n in functionRegistry) !is null);
            if (qualified.length > 0) {
                return functionRegistry[qualified];
            }
        }
        return null;
    }

    // Decides whether member access on `object` should use "." (a value
    // type: struct, array element, or dereferenced pointer) or "->" (a class
    // instance, always heap-allocated, or an explicit pointer type). Falls
    // back to "->" - the historical, only behavior before structs existed -
    // whenever the type can't be determined, so existing class-based code
    // is unaffected.
    private string memberAccessor(ASTNode object) {
        try {
            Type t = inferType(object);
            if (!t.isPointer && isStructTypeName(t.name)) {
                return ".";
            }
            return "->";
        } catch (Exception e) {
            return "->";
        }
    }

    // Finds the operator-overload method (see ast.operatorMethodName) a
    // class defines for `op`, given the left/self operand's inferred type.
    // Returns null if there isn't one - the caller falls back to the plain
    // C operator.
    private FunctionDecl findOperatorMethod(ASTNode selfOperand, string op, bool isUnary) {
        string methodName = operatorMethodName(op, isUnary);
        if (methodName.length == 0) return null;
        try {
            Type selfType = inferType(selfOperand);
            resolveType(selfType);
            if (auto classDecl = selfType.name in classRegistry) {
                foreach (method; classDecl.methods) {
                    if (method.name == methodName) return method;
                }
            }
        } catch (Exception e) {
            // fall through - not an overload
        }
        return null;
    }

    private string tryBinaryOperatorOverloadCall(BinaryExpr binExpr) {
        FunctionDecl method = findOperatorMethod(binExpr.left, binExpr.op, false);
        if (method is null) return "";
        Type selfType = inferType(binExpr.left);
        resolveType(selfType);
        return format("%s_%s(%s, %s)", selfType.name, method.name,
            generateExpression(binExpr.left), generateExpression(binExpr.right));
    }

    private string tryUnaryOperatorOverloadCall(UnaryExpr unaryExpr) {
        FunctionDecl method = findOperatorMethod(unaryExpr.operand, unaryExpr.op, true);
        if (method is null) return "";
        Type selfType = inferType(unaryExpr.operand);
        resolveType(selfType);
        return format("%s_%s(%s)", selfType.name, method.name, generateExpression(unaryExpr.operand));
    }

    // Tries to resolve a dotted chain as a namespace-qualified reference
    // (checked via `exists`, e.g. against functionRegistry or variableTypes)
    // rather than instance member access. Returns "" if it isn't one.
    private string tryResolveQualifiedPath(ASTNode expr, bool delegate(string) exists) {
        string root = leftmostName(expr);
        if (root.length == 0 || (root in variableTypes)) {
            return ""; // root is a real local/instance variable; prefer normal member access
        }

        string flat = flattenPath(expr);
        if (flat.length == 0) return "";

        if (exists(flat)) return flat;
        foreach (candidate; enclosingQualifications(flat)) {
            if (exists(candidate)) return candidate;
        }
        return "";
    }

    // Extern functions are always registered under their bare, unmangled
    // name (see mangledFunc) since they bind to a real external C symbol
    // regardless of how they're namespaced at the declaration site - so a
    // call like `HAL.Log.ksnprintf(...)` needs this narrow fallback after
    // tryResolveQualifiedPath's mangled-path lookup comes up empty. Scoped
    // to extern functions specifically (not a blanket bare-name fallback)
    // to avoid silently matching an unrelated same-named top-level symbol.
    private string tryResolveExternFunctionMember(ASTNode expr) {
        if (auto member = cast(MemberExpr)expr) {
            if (auto fd = member.member in functionRegistry) {
                if (fd.isExtern) return member.member;
            }
        }
        return "";
    }

    // Resolves a bare (unqualified) name, letting sibling code inside a
    // namespace refer to other members of that namespace (or an enclosing
    // one) without prefixing.
    private string resolveName(string name, bool delegate(string) exists) {
        if (exists(name)) return name;
        foreach (candidate; enclosingQualifications(name)) {
            if (exists(candidate)) return candidate;
        }
        return name;
    }

    private string generateExpression(ASTNode node) {
        if (auto binExpr = cast(BinaryExpr)node) {
            if (binExpr.op == "=") {
                checkNotConstAssignment(binExpr.left);
                return generateExpression(binExpr.left) ~ " = " ~ generateExpression(binExpr.right);
            }
            string overloadCall = tryBinaryOperatorOverloadCall(binExpr);
            if (overloadCall.length > 0) {
                return overloadCall;
            }
            return "(" ~ generateExpression(binExpr.left) ~ " " ~ binExpr.op ~ " " ~
                   generateExpression(binExpr.right) ~ ")";
        } else if (auto unaryExpr = cast(UnaryExpr)node) {
            string overloadCall = tryUnaryOperatorOverloadCall(unaryExpr);
            if (overloadCall.length > 0) {
                return overloadCall;
            }
            return unaryExpr.op ~ generateExpression(unaryExpr.operand);
        } else if (auto callExpr = cast(CallExpr)node) {
            // Check if this is a method call
            if (auto memberExpr = cast(MemberExpr)callExpr.callee) {
                // A namespace-qualified function call (e.g. Graphics.helper())
                // takes priority over instance-method-call syntax.
                string qualifiedFunc = tryResolveQualifiedPath(memberExpr,
                    (n) => (n in functionRegistry) !is null);
                if (qualifiedFunc.length == 0) {
                    qualifiedFunc = tryResolveExternFunctionMember(memberExpr);
                }
                if (qualifiedFunc.length > 0) {
                    FunctionDecl qualifiedDecl = functionRegistry[qualifiedFunc];
                    string qargs = "";
                    foreach (i, arg; callExpr.args) {
                        if (i > 0) qargs ~= ", ";
                        string argCode = generateExpression(arg);
                        if (qualifiedDecl.isVariadic && i >= qualifiedDecl.params.length) {
                            argCode = variadicPromote(arg, argCode);
                        }
                        qargs ~= argCode;
                    }
                    return format("%s(%s)", qualifiedFunc, qargs);
                }

                string objectExpr = generateExpression(memberExpr.object);
                string methodName = memberExpr.member;

                // Try to determine the class type
                string className = "";
                if (auto objIdent = cast(Identifier)memberExpr.object) {
                    if (objIdent.name in variableTypes) {
                        className = variableTypes[objIdent.name].name;
                    }
                }

                // Generate method call with object as first parameter
                string args = objectExpr;
                foreach (arg; callExpr.args) {
                    args ~= ", " ~ generateExpression(arg);
                }

                if (className.length > 0) {
                    return format("%s_%s(%s)", className, methodName, args);
                } else {
                    return format("CLASS_%s(%s)", methodName, args);
                }
            } else {
                string callee = generateExpression(callExpr.callee);
                FunctionDecl calleeDecl = resolveCalledFunction(callExpr.callee);
                string args = "";
                foreach (i, arg; callExpr.args) {
                    if (i > 0) args ~= ", ";
                    string argCode = generateExpression(arg);
                    if (calleeDecl !is null && calleeDecl.isVariadic && i >= calleeDecl.params.length) {
                        argCode = variadicPromote(arg, argCode);
                    }
                    args ~= argCode;
                }
                return format("%s(%s)", callee, args);
            }
        } else if (auto memberExpr = cast(MemberExpr)node) {
            // A namespace-qualified global reference (e.g. Graphics.origin)
            // takes priority over instance field access.
            string qualifiedVar = tryResolveQualifiedPath(memberExpr, (n) => (n in variableTypes) !is null);
            if (qualifiedVar.length > 0) {
                return qualifiedVar;
            }

            string accessor = memberAccessor(memberExpr.object);
            return format("%s%s%s", generateExpression(memberExpr.object), accessor, memberExpr.member);
        } else if (auto indexExpr = cast(IndexExpr)node) {
            return format("%s[%s]", generateExpression(indexExpr.array),
                         generateExpression(indexExpr.index));
        } else if (auto ident = cast(Identifier)node) {
            return resolveName(ident.name,
                (n) => (n in variableTypes) !is null || (n in functionRegistry) !is null);
        } else if (auto intLit = cast(IntLiteral)node) {
            return to!string(intLit.value);
        } else if (auto strLit = cast(StringLiteral)node) {
            return format("\"%s\"", escapeCString(strLit.value));
        } else if (auto boolLit = cast(BoolLiteral)node) {
            return boolLit.value ? "1" : "0";
        } else if (auto nullLit = cast(NullLiteral)node) {
            return "NULL";
        } else if (auto newExpr = cast(NewExpr)node) {
            resolveType(newExpr.type);
            checkNotStruct(newExpr);
            string args = "";
            foreach (i, arg; newExpr.args) {
                if (i > 0) args ~= ", ";
                args ~= generateExpression(arg);
            }
            return format("%s_new(%s)", newExpr.type.name, args);
        } else if (auto castExpr = cast(CastExpr)node) {
            resolveType(castExpr.type);
            return format("((%s)%s)", typeToC(castExpr.type), generateExpression(castExpr.expression));
        }

        return "";
    }

    // Infers the type of an expression used as a `let` initializer when no
    // explicit type annotation was given.
    private CompileError inferError(ASTNode node, string message) {
        return new CompileError(message, currentModulePath, node.line, node.column);
    }

    private Type inferType(ASTNode expr) {
        if (cast(IntLiteral)expr) {
            return new Type("int");
        } else if (cast(StringLiteral)expr) {
            return new Type("char", true);
        } else if (cast(BoolLiteral)expr) {
            return new Type("bool");
        } else if (cast(NullLiteral)expr) {
            throw inferError(expr, "Cannot infer type from 'null'; add an explicit type annotation");
        } else if (auto newExpr = cast(NewExpr)expr) {
            resolveType(newExpr.type);
            checkNotStruct(newExpr);
            return new Type(newExpr.type.name);
        } else if (auto castExpr = cast(CastExpr)expr) {
            resolveType(castExpr.type);
            return castExpr.type;
        } else if (auto ident = cast(Identifier)expr) {
            string resolved = resolveName(ident.name, (n) => (n in variableTypes) !is null);
            if (resolved in variableTypes) {
                return variableTypes[resolved];
            }
            throw inferError(expr, format("Cannot infer type: unknown variable '%s'", ident.name));
        } else if (auto memberExpr = cast(MemberExpr)expr) {
            string qualifiedVar = tryResolveQualifiedPath(memberExpr, (n) => (n in variableTypes) !is null);
            if (qualifiedVar.length > 0) {
                return variableTypes[qualifiedVar];
            }

            Type objType = inferType(memberExpr.object);
            if (auto classDecl = objType.name in classRegistry) {
                foreach (field; classDecl.fields) {
                    if (field.name == memberExpr.member) {
                        if (field.type is null) {
                            field.type = inferType(field.initializer);
                        }
                        return field.type;
                    }
                }
            }
            if (auto structDecl = objType.name in structRegistry) {
                foreach (field; structDecl.fields) {
                    if (field.name == memberExpr.member) {
                        if (field.type is null) {
                            field.type = inferType(field.initializer);
                        }
                        return field.type;
                    }
                }
            }
            throw inferError(expr, format("Cannot infer type of field '%s'", memberExpr.member));
        } else if (auto callExpr = cast(CallExpr)expr) {
            if (auto memberCallee = cast(MemberExpr)callExpr.callee) {
                string qualifiedFunc = tryResolveQualifiedPath(memberCallee, (n) => (n in functionRegistry) !is null);
                if (qualifiedFunc.length == 0) {
                    qualifiedFunc = tryResolveExternFunctionMember(memberCallee);
                }
                if (qualifiedFunc.length > 0) {
                    return functionRegistry[qualifiedFunc].returnType;
                }

                Type objType = inferType(memberCallee.object);
                if (auto classDecl = objType.name in classRegistry) {
                    foreach (method; classDecl.methods) {
                        if (method.name == memberCallee.member) {
                            return method.returnType;
                        }
                    }
                }
                throw inferError(expr, format("Cannot infer type: unknown method '%s'", memberCallee.member));
            } else if (auto calleeIdent = cast(Identifier)callExpr.callee) {
                string resolved = resolveName(calleeIdent.name, (n) => (n in functionRegistry) !is null);
                if (auto funcDecl = resolved in functionRegistry) {
                    return funcDecl.returnType;
                }
                throw inferError(expr, format("Cannot infer type: unknown function '%s'", calleeIdent.name));
            }
            throw inferError(expr, "Cannot infer type of call expression");
        } else if (auto binExpr = cast(BinaryExpr)expr) {
            FunctionDecl binOpMethod = findOperatorMethod(binExpr.left, binExpr.op, false);
            if (binOpMethod !is null) {
                return binOpMethod.returnType;
            }
            switch (binExpr.op) {
                case "==": case "!=": case "<": case ">": case "<=": case ">=":
                case "&&": case "||":
                    return new Type("bool");
                default:
                    return inferType(binExpr.left);
            }
        } else if (auto unaryExpr = cast(UnaryExpr)expr) {
            FunctionDecl unaryOpMethod = findOperatorMethod(unaryExpr.operand, unaryExpr.op, true);
            if (unaryOpMethod !is null) {
                return unaryOpMethod.returnType;
            }
            if (unaryExpr.op == "!") {
                return new Type("bool");
            } else if (unaryExpr.op == "&") {
                Type inner = inferType(unaryExpr.operand);
                return new Type(inner.name, true, inner.isArray, inner.arraySize);
            } else if (unaryExpr.op == "*") {
                Type inner = inferType(unaryExpr.operand);
                if (!inner.isPointer) {
                    throw inferError(expr, "Cannot infer type: dereferencing a non-pointer");
                }
                return new Type(inner.name, false, inner.isArray, inner.arraySize);
            }
            return inferType(unaryExpr.operand);
        } else if (auto indexExpr = cast(IndexExpr)expr) {
            Type arrType = inferType(indexExpr.array);
            if (arrType.isArray || arrType.isPointer) {
                return new Type(arrType.name, false, false, 0);
            }
            throw inferError(expr, "Cannot infer type: indexing a non-array, non-pointer value");
        }

        throw inferError(expr, "Cannot infer type of this expression; add an explicit type annotation");
    }

    // Maps a base LLPL primitive type name to its C equivalent, leaving
    // anything else (class names) unchanged. Shared by typeToC and the
    // array-declaration code paths, which need the base type without
    // typeToC's pointer-star handling.
    private string primitiveToC(string name) {
        switch (name) {
            case "int": return "int64_t";    // 64-bit integer
            case "uint": return "uint64_t";  // 64-bit unsigned
            case "int16": return "int16_t";
            case "uint16": return "uint16_t";
            case "int32": return "int32_t";
            case "uint32": return "uint32_t";
            case "char": return "char";
            case "bool": return "int";
            case "void": return "void";
            default: return name;
        }
    }

    private string typeToC(Type type) {
        string cType = primitiveToC(type.name);

        // Classes are always heap-allocated and accessed by pointer; structs
        // are plain value types with no such auto-pointering.
        if (!isPrimitiveTypeName(type.name) && !isStructTypeName(type.name)) {
            if (!type.isPointer && !type.isArray) {
                cType ~= "*"; // Classes are always pointers
            }
        }

        if (type.isPointer) {
            cType ~= "*";
        }

        // Don't add array notation here - it's handled specially in var declarations
        // because C requires array size after variable name

        return cType;
    }
}

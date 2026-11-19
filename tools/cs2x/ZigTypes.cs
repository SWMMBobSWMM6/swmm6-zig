// ZigTypes.cs - C# types to Zig types, and the declarations of the Zig engine: structs for classes (an embedded
// __base for a derived class, a __tid type id at the root of a hierarchy), integer constants for enums, functions for
// methods and constructors, globals for static fields, and the virtual-call dispatchers.
// Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Operations;

public static partial class Cs2Zig
{
    // ------------------------------------------------------------------------------------------------ hierarchy
    static readonly HashSet<INamedTypeSymbol> hasDerived = new(SymbolEqualityComparer.Default);
    static readonly List<INamedTypeSymbol> engineTypes = new();
    static readonly Dictionary<INamedTypeSymbol, int> tids = new(SymbolEqualityComparer.Default);

    static bool IsEngine(ITypeSymbol? t) => t is INamedTypeSymbol n && !IsRuntime(n) && !IsSystem(n) && n.Locations.Any(l => l.IsInSource);

    static void CollectTypes(List<SyntaxTree> gen)
    {
        var seen = new HashSet<INamedTypeSymbol>(SymbolEqualityComparer.Default);
        foreach (var t in gen)
            foreach (var td in t.GetRoot().DescendantNodes().OfType<BaseTypeDeclarationSyntax>())
            {
                var s = (INamedTypeSymbol)M(td).GetDeclaredSymbol(td)!;
                if (seen.Add(s)) engineTypes.Add(s);
            }
        foreach (var s in engineTypes)
            for (var b = s.BaseType; b != null && IsEngine(b); b = b.BaseType) hasDerived.Add(b.OriginalDefinition);
        int next = 1000;
        foreach (var s in engineTypes.OrderBy(x => TypeIdent(x), StringComparer.Ordinal))
            if (s.TypeKind == TypeKind.Class && !s.IsStatic && InHierarchy(s)) tids[s.OriginalDefinition] = next++;
    }

    /// <summary>The engine class has a base class other than object, or a class derives from it.</summary>
    static bool InHierarchy(INamedTypeSymbol t)
    {
        t = t.OriginalDefinition;
        if (hasDerived.Contains(t)) return true;
        var b = t.BaseType;
        return b != null && b.SpecialType != SpecialType.System_Object && (IsEngine(b) || IsRuntime(b));
    }

    static INamedTypeSymbol? EngineBase(INamedTypeSymbol t) => t.BaseType != null && IsEngine(t.BaseType) ? t.BaseType.OriginalDefinition : null;

    /// <summary>The path from an object of type t to its type id field.</summary>
    static string TidPath(INamedTypeSymbol t)
    {
        var s = new StringBuilder();
        var c = t.OriginalDefinition;
        while (true)
        {
            var b = c.BaseType;
            if (b != null && IsEngine(b)) { s.Append(".__base"); c = b.OriginalDefinition; continue; }
            if (b != null && IsRuntime(b)) { s.Append(".__base.tid"); return s.ToString(); }
            s.Append(".__tid");
            return s.ToString();
        }
    }

    static int Tid(INamedTypeSymbol t) => tids.TryGetValue(t.OriginalDefinition, out var v) ? v : Todo("type id of " + t.Name) is var _ ? 0 : 0;

    // the runtime's exception kinds (zig/rt/exc.zig)
    static readonly Dictionary<string, int> runtimeExcKinds = new()
    {
        ["CppException"] = 1, ["LogicError"] = 2, ["RuntimeError"] = 3, ["InvalidArgument"] = 4, ["OutOfRange"] = 5,
        ["LengthError"] = 6, ["DomainError"] = 7, ["RangeError"] = 8, ["OverflowError"] = 9, ["BadAlloc"] = 10,
        ["BadOptionalAccess"] = 11, ["BadFunctionCall"] = 12, ["BadVariantAccess"] = 13,
        ["Exception"] = 100, ["NotImplementedException"] = 101, ["InvalidOperationException"] = 102,
        ["NotSupportedException"] = 103, ["ArgumentException"] = 104, ["IndexOutOfRangeException"] = 105,
    };

    static bool IsExceptionType(ITypeSymbol t)
    {
        for (var b = t as INamedTypeSymbol; b != null; b = b.BaseType)
            if ((IsRuntime(b) && b.Name == "CppException") || (IsSystem(b) && b.Name == "Exception")) return true;
        return false;
    }

    /// <summary>The type id a catch clause or an `is` test compares against.</summary>
    static int TargetTid(INamedTypeSymbol t)
    {
        if (IsEngine(t)) return Tid(t);
        if (runtimeExcKinds.TryGetValue(t.Name, out var k)) return k;
        return Todo("type id of " + t.ToDisplayString()) is var _ ? 0 : 0;
    }

    static string TypeIdTables()
    {
        var sb = new StringBuilder("// ---------------------------------------------------------------- type ids\n");
        sb.Append("pub fn __tid_parent(t: u32) u32 {\n    return switch (t) {\n");
        foreach (var kv in tids.OrderBy(k => k.Value))
        {
            var b = kv.Key.BaseType;
            int p = 0;
            if (b != null && IsEngine(b)) p = Tid(b);
            else if (b != null && IsRuntime(b)) p = runtimeExcKinds.TryGetValue(b.Name, out var k) ? k : 0;
            sb.Append("        ").Append(kv.Value).Append(" => ").Append(p).Append(", // ").Append(TypeIdent(kv.Key)).Append('\n');
        }
        sb.Append("        else => rt.excParent(t),\n    };\n}\n\n");
        sb.Append("pub fn __isA(t: u32, target: u32) bool {\n    var x = t;\n    while (x != 0) : (x = __tid_parent(x)) {\n        if (x == target) return true;\n    }\n    return false;\n}\n\n");
        return sb.ToString();
    }

    // ------------------------------------------------------------------------------------------------ types
    public static string ZigType(ITypeSymbol t)
    {
        switch (t.SpecialType)
        {
            case SpecialType.System_Boolean: return "bool";
            case SpecialType.System_SByte: return "i8";
            case SpecialType.System_Byte: return "u8";
            case SpecialType.System_Int16: return "i16";
            case SpecialType.System_UInt16: return "u16";
            case SpecialType.System_Int32: return "i32";
            case SpecialType.System_UInt32: return "u32";
            case SpecialType.System_Int64: return "i64";
            case SpecialType.System_UInt64: return "u64";
            case SpecialType.System_Single: return "f32";
            case SpecialType.System_Double: return "f64";
            case SpecialType.System_Char: return "u16";
            case SpecialType.System_String: return "?[]const u8";
            case SpecialType.System_Object: return "rt.Obj";
            case SpecialType.System_Void: return "void";
            case SpecialType.System_IntPtr: return "isize";
        }
        if (t is IArrayTypeSymbol at)
        {
            if (at.Rank != 1) Todo("multidimensional array");
            return "?[]" + ZigType(at.ElementType);
        }
        if (t is ITypeParameterSymbol tp) return tp.Name;
        if (t is INamedTypeSymbol n)
        {
            if (n.TypeKind == TypeKind.Delegate) return DelegateType(n);
            if (IsRuntime(n)) return RuntimeType(n);
            if (IsSystem(n))
            {
                if (IsExceptionType(n)) return "?*rt.CppException";
                if (n.Name == "IDisposable") return "rt.Obj";
                if (n.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T) return ZigType(n.TypeArguments[0]);
                return Todo("system type " + n.ToDisplayString());
            }
            if (n.TypeKind == TypeKind.Enum) return TypeIdent(n);
            if (n.TypeKind == TypeKind.Interface) return Todo("engine interface type " + n.Name);
            return "?*" + TypeIdent(n);
        }
        return Todo("type " + t.ToDisplayString());
    }

    static string RuntimeType(INamedTypeSymbol n)
    {
        var name = StripArity(n.Name);
        switch (name)
        {
            case "CPtr": return "?[*]u8";
            case "Ptr": return "?[*]" + ZigType(n.TypeArguments[0]);
            case "Raw": return "void";
        }
        if (IsExceptionType(n)) return "?*rt.CppException";
        // the streams are two Zig types: every input stream an IStream, every output stream an OStream
        if (name is "IStringStream" or "IFStream" or "IStream") return "?*rt.IStream";
        if (name is "OStringStream" or "OFStream" or "OStream") return "?*rt.OStream";
        var s = "rt." + RuntimeTypeName(n);
        Use("type " + n.OriginalDefinition.ToDisplayString(), s);
        return n.TypeKind == TypeKind.Struct || n.TypeKind == TypeKind.Enum ? s : "?*" + s;
    }

    /// <summary>The runtime's Zig type, without the pointer of a class: rt.Vec(f64), rt.Str.</summary>
    static string RuntimeTypeName(INamedTypeSymbol n)
    {
        var parts = new List<string>();
        for (var c = n; c != null; c = c.ContainingType) parts.Insert(0, StripArity(c.Name));
        var s = string.Join("_", parts);
        if (n.TypeArguments.Length > 0) s += "(" + string.Join(", ", n.TypeArguments.Select(ZigType)) + ")";
        return s;
    }

    static string StripArity(string s) { var i = s.IndexOf('`'); return i < 0 ? s : s.Substring(0, i); }

    static void Use(string key, string zig) { manifest[key] = zig; }

    /// <summary>A delegate: rt.FnN(parameter types..., return type), the parameters of a ref kind as pointers.</summary>
    static string DelegateType(INamedTypeSymbol n)
    {
        var inv = n.DelegateInvokeMethod!;
        var ps = inv.Parameters.Select(ParamType).ToList();
        ps.Add(RetType(inv));
        return "rt.Fn" + inv.Parameters.Length + "(" + string.Join(", ", ps) + ")";
    }

    static string ParamType(IParameterSymbol p) => (p.RefKind != RefKind.None ? "*" : "") + ZigType(p.Type);
    static string RetType(IMethodSymbol m) => m.ReturnsVoid ? "void" : (m.RefKind != RefKind.None ? "*" : "") + ZigType(m.ReturnType);

    static bool IsClassRef(ITypeSymbol t) => t.TypeKind == TypeKind.Class && t.SpecialType != SpecialType.System_String && t.SpecialType != SpecialType.System_Object;

    // ------------------------------------------------------------------------------------------------ declarations
    static void TypeDecl(BaseTypeDeclarationSyntax td, StringBuilder sb, HashSet<INamedTypeSymbol> declared)
    {
        var s = (INamedTypeSymbol)M(td).GetDeclaredSymbol(td)!;
        if (td is EnumDeclarationSyntax)
        {
            if (!declared.Add(s)) return;
            var ut = ZigType(s.EnumUnderlyingType!);
            var nm = TypeIdent(s);
            sb.Append("pub const ").Append(nm).Append(" = ").Append(ut).Append(";\n");
            foreach (var f in s.GetMembers().OfType<IFieldSymbol>().Where(f => f.HasConstantValue))
                sb.Append("pub const ").Append(nm).Append("__").Append(f.Name.TrimStart('@')).Append(": ").Append(ut).Append(" = ").Append(IntLit(f.ConstantValue!)).Append(";\n");
            sb.Append('\n');
            return;
        }
        if (td is not ClassDeclarationSyntax cd) { sb.Append("// TODO type declaration ").Append(td.Kind()).Append('\n'); Note("type declaration " + td.Kind()); return; }
        if (!s.IsStatic && declared.Add(s)) StructDecl(s, sb);
        foreach (var m in cd.Members)
        {
            var mark = funcs.Length;
            try
            {
                switch (m)
                {
                    case MethodDeclarationSyntax md: MethodDecl(md, s); break;
                    case ConstructorDeclarationSyntax ctor: CtorDecl(ctor, s); break;
                    case FieldDeclarationSyntax fd: StaticFieldDecl(fd, s); break;
                    case BaseTypeDeclarationSyntax: break;      // nested: declared on its own
                    case DelegateDeclarationSyntax: break;
                    default: funcs.Append("// TODO member ").Append(m.Kind()).Append('\n'); Note("member " + m.Kind()); break;
                }
            }
            catch (Todo e) { funcs.Length = mark; funcs.Append("// TODO ").Append(e.Message.Replace("\n", " ")).Append('\n'); }
            catch (Exception e) when (e is not global::Todo)
            {
                funcs.Length = mark;
                funcs.Append("// TODO translator error: ").Append(e.GetType().Name).Append(' ').Append(e.Message.Replace("\n", " ")).Append('\n');
                Note("translator error " + e.GetType().Name + " " + e.Message.Split('\n')[0]);
            }
        }
    }

    static IMethodSymbol? FindMethod(INamedTypeSymbol s, string name, int nparams) =>
        s.GetMembers(name).OfType<IMethodSymbol>().FirstOrDefault(m => m.Parameters.Length == nparams && !m.IsStatic && m.MethodKind == MethodKind.Ordinary);

    static bool Implements(INamedTypeSymbol s, string iface) => s.AllInterfaces.Any(i => (IsRuntime(i) || IsSystem(i)) && StripArity(i.Name) == iface);

    static void StructDecl(INamedTypeSymbol s, StringBuilder sb)
    {
        var nm = TypeIdent(s);
        sb.Append("pub const ").Append(nm).Append(" = struct {\n");
        var b = s.BaseType;
        if (b != null && IsEngine(b)) sb.Append("    __base: ").Append(TypeIdent(b)).Append(",\n");
        else if (b != null && IsRuntime(b))
        {
            if (!IsExceptionType(b)) Todo("engine class " + s.Name + " derives from runtime class " + b.Name);
            sb.Append("    __base: rt.CppException,\n");
        }
        else if (InHierarchy(s)) sb.Append("    __tid: u32,\n");
        foreach (var f in s.GetMembers().OfType<IFieldSymbol>().Where(f => !f.IsStatic && !f.IsConst))
        {
            string zt;
            try { zt = ZigType(f.Type); } catch (Todo e) { zt = "rt.Obj, // TODO " + e.Message; }
            sb.Append("    ").Append(FieldIdent(f)).Append(": ").Append(zt).Append(",\n");
        }
        // the runtime's protocol: how a container makes, copies, assigns, moves and destroys an element
        if (!s.IsAbstract && s.InstanceConstructors.Any(c => c.Parameters.Length == 0 && c.DeclaringSyntaxReferences.Length > 0))
            sb.Append("    pub const __new = ").Append(nm).Append("__new;\n");
        var clone = FindMethod(s, "Clone", 0);
        if (clone != null) sb.Append("    pub const __clone = ").Append(FuncName(clone)).Append(";\n");
        var assign = s.GetMembers("Assign").OfType<IMethodSymbol>().FirstOrDefault(m => m.Parameters.Length == 1 && SymbolEqualityComparer.Default.Equals(m.Parameters[0].Type.OriginalDefinition, s.OriginalDefinition));
        if (assign != null) sb.Append("    pub const __assign = ").Append(FuncName(assign)).Append(";\n");
        var move = s.GetMembers("MoveFrom").OfType<IMethodSymbol>().FirstOrDefault(m => m.Parameters.Length == 1 && SymbolEqualityComparer.Default.Equals(m.Parameters[0].Type.OriginalDefinition, s.OriginalDefinition));
        if (move != null) sb.Append("    pub const __moveFrom = ").Append(FuncName(move)).Append(";\n");
        if (NeedsDisposeDispatch(s)) sb.Append("    pub const __dispose = ").Append(DisposeFn(s)).Append(";\n");
        var hashOf = FindMethod(s, "HashOf", 1);
        if (hashOf != null) sb.Append("    pub const __hashOf = ").Append(FuncName(hashOf)).Append(";\n");
        var call2 = FindMethod(s, "Call2", 2);
        if (call2 != null) sb.Append("    pub const __call2 = ").Append(FuncName(call2)).Append(";\n");
        sb.Append("};\n\n");
        // the C# Raw constructor: the object with its fields zero (C#'s defaults), its type id, and a runtime base's
        // own default construction
        if (s.TypeKind == TypeKind.Class)
        {
            var raw = new StringBuilder();
            raw.Append("pub fn ").Append(nm).Append("__raw() E!?*").Append(nm).Append(" {\n    const o = rt.gcNew(").Append(nm).Append(");\n");
            if (tids.ContainsKey(s.OriginalDefinition)) raw.Append("    o").Append(TidPath(s)).Append(" = ").Append(Tid(s)).Append(";\n");
            var root = s; var path = "";
            while (root.BaseType != null && IsEngine(root.BaseType)) { root = root.BaseType; path += ".__base"; }
            if (root.BaseType != null && IsRuntime(root.BaseType)) raw.Append("    try rt.CppException.initDefault(&o").Append(path).Append(".__base);\n");
            raw.Append("    return o;\n}\n\n");
            funcs.Append(raw);
        }
    }

    // ---- destructors: Dtor.Run on an engine object runs its Dispose, found by its type id when it is in a hierarchy
    static bool HasDispose(INamedTypeSymbol s) => Implements(s, "IDisposable") && FindMethod(s, "Dispose", 0) != null;

    static IEnumerable<INamedTypeSymbol> Descendants(INamedTypeSymbol s) =>
        engineTypes.Where(x => x.TypeKind == TypeKind.Class && !x.IsStatic && DerivesOrSame(x, s));

    static bool DerivesOrSame(INamedTypeSymbol d, INamedTypeSymbol b)
    {
        for (INamedTypeSymbol? x = d; x != null; x = x.BaseType) if (SymbolEqualityComparer.Default.Equals(x.OriginalDefinition, b.OriginalDefinition)) return true;
        return false;
    }

    static bool NeedsDisposeDispatch(INamedTypeSymbol s) => Descendants(s).Any(HasDispose);

    static readonly HashSet<string> disposeFns = new();

    static string DisposeFn(INamedTypeSymbol s)
    {
        var nm = TypeIdent(s) + "____dispose";
        if (!disposeFns.Add(nm)) return nm;
        var f = new StringBuilder();
        f.Append("pub fn ").Append(nm).Append("(this: ?*").Append(TypeIdent(s)).Append(") E!void {\n    const o = this orelse return;\n");
        if (tids.ContainsKey(s.OriginalDefinition))
        {
            f.Append("    switch (o").Append(TidPath(s)).Append(") {\n");
            foreach (var d in Descendants(s).Where(HasDispose))
            {
                var m = FindMethod(d, "Dispose", 0)!;
                f.Append("        ").Append(Tid(d)).Append(" => return ").Append(FuncName(m)).Append("(").Append(Downcast("o", s, d)).Append("),\n");
            }
            f.Append("        else => {},\n    }\n");
        }
        else f.Append("    return ").Append(FuncName(FindMethod(s, "Dispose", 0)!)).Append("(o);\n");
        f.Append("}\n\n");
        funcs.Append(f);
        return nm;
    }

    /// <summary>A non-null pointer expression p of engine type b, seen as its derived type d (a *d).</summary>
    static string Downcast(string p, INamedTypeSymbol b, INamedTypeSymbol d)
    {
        var chain = new List<INamedTypeSymbol>();
        for (var x = d.OriginalDefinition; !SymbolEqualityComparer.Default.Equals(x, b.OriginalDefinition); x = x.BaseType!.OriginalDefinition) chain.Add(x);
        var e = p;
        for (int i = chain.Count - 1; i >= 0; i--) e = "@as(*" + TypeIdent(chain[i]) + ", @alignCast(@fieldParentPtr(\"__base\", " + e + ")))";
        return e;
    }

    /// <summary>The path from an object of type d to its embedded base b (".__base.__base").</summary>
    static string BasePath(INamedTypeSymbol d, INamedTypeSymbol b)
    {
        var s = new StringBuilder();
        for (var x = d.OriginalDefinition; !SymbolEqualityComparer.Default.Equals(x, b.OriginalDefinition); x = x.BaseType!.OriginalDefinition) s.Append(".__base");
        return s.ToString();
    }

    static string IntLit(object v) => v switch
    {
        int i => i.ToString(), long l => l.ToString(), uint u => u.ToString(), ulong ul => ul.ToString(),
        short sh => sh.ToString(), ushort us => us.ToString(), byte by => by.ToString(), sbyte sb => sb.ToString(),
        _ => v.ToString()!
    };

    static void StaticFieldDecl(FieldDeclarationSyntax fd, INamedTypeSymbol s)
    {
        foreach (var v in fd.Declaration.Variables)
        {
            var f = (IFieldSymbol)M(fd).GetDeclaredSymbol(v)!;
            if (!f.IsStatic || f.IsConst) continue;
            var zt = ZigType(f.Type);
            var name = StaticFieldName(f);
            statics.Append("pub var ").Append(name).Append(": ").Append(zt).Append(" = std.mem.zeroes(").Append(zt).Append(");\n");
            if (v.Initializer == null) continue;
            var fi = M(fd).GetOperation(v.Initializer) as IFieldInitializerOperation;
            var op = fi?.Value ?? M(fd).GetOperation(v.Initializer.Value);
            if (op == null) { staticInit.Add("    // TODO initializer of " + name + "\n"); Note("static initializer"); continue; }
            var ctx = new Fn(null, s, "void");
            try
            {
                var lines = new List<string>();
                ctx.AssignInto(name, op, f.Type, lines, 1);
                staticInit.Add(string.Concat(lines.Select(l => l + "\n")));
            }
            catch (Todo e) { staticInit.Add("    // TODO initializer of " + name + ": " + e.Message.Replace("\n", " ") + "\n"); }
        }
    }

    static void MethodDecl(MethodDeclarationSyntax md, INamedTypeSymbol s)
    {
        var m = (IMethodSymbol)M(md).GetDeclaredSymbol(md)!;
        if (m.IsAbstract || (md.Body == null && md.ExpressionBody == null)) return;
        var fn = new Fn(m, s, RetType(m));
        var head = new StringBuilder("pub fn ").Append(FuncName(m)).Append('(');
        var ps = new List<string>();
        if (!m.IsStatic) ps.Add("this: ?*" + TypeIdent(s));
        foreach (var p in m.Parameters) ps.Add(fn.ParamName(p) + ": " + ParamType(p));
        head.Append(string.Join(", ", ps)).Append(") E!").Append(RetType(m));
        IOperation? op = md.Body != null ? M(md).GetOperation(md.Body) : M(md).GetOperation(md.ExpressionBody!);
        string body = op == null ? "" : fn.Body(op, m.Parameters, !m.IsStatic);
        funcs.Append(head).Append(" {\n").Append(body).Append("}\n\n");
        if (m.IsVirtual && !m.IsOverride && tids.ContainsKey(s.OriginalDefinition)) VDispatch(m);
    }

    static void CtorDecl(ConstructorDeclarationSyntax cd, INamedTypeSymbol s)
    {
        var c = (IMethodSymbol)M(cd).GetDeclaredSymbol(cd)!;
        if (c.IsStatic) { Todo("static constructor"); return; }
        var nm = TypeIdent(s);
        if (c.Parameters.Length == 1 && c.Parameters[0].Type.Name == "Raw")
        {
            if (cd.Body != null && cd.Body.Statements.Count > 0) Todo("raw constructor with a body in " + s.Name);
            return;
        }
        if (c.Parameters.Length != 0) { Todo("constructor with parameters in " + s.Name); return; }
        if (s.IsAbstract) return;
        // X() : this(Raw.V) { body }: the raw object, then the body
        var init = cd.Initializer;
        if (init != null && !(init.ThisOrBaseKeyword.IsKind(SyntaxKind.ThisKeyword) && init.ArgumentList.Arguments.Count == 1))
            Todo("constructor initializer in " + s.Name);
        var fn = new Fn(c, s, "?*" + nm);
        string body = "";
        if (cd.Body != null && cd.Body.Statements.Count > 0) body = fn.Body(M(cd).GetOperation(cd.Body)!, c.Parameters, true, true);
        funcs.Append("pub fn ").Append(nm).Append("__new() E!?*").Append(nm).Append(" {\n    const this: ?*").Append(nm).Append(" = try ").Append(nm).Append("__raw();\n")
            .Append(body).Append("    return this;\n}\n\n");
    }

    // ---- virtual calls: a dispatcher per method that introduces a virtual (the root of its override chain), switching on
    // the object's type id to the most derived override for that type
    static readonly HashSet<string> vdispatch = new();

    public static IMethodSymbol VRoot(IMethodSymbol m)
    {
        m = m.OriginalDefinition;
        while (m.OverriddenMethod != null) m = m.OverriddenMethod.OriginalDefinition;
        return m;
    }

    public static string VDispatch(IMethodSymbol m)
    {
        var root = VRoot(m);
        var b = root.ContainingType.OriginalDefinition;
        var name = FuncName(root) + "__v";
        if (!vdispatch.Add(name)) return name;
        if (!IsEngine(b)) Todo("virtual method of a runtime class: " + root.ToDisplayString());
        var f = new StringBuilder();
        var ps = new List<string> { "this: ?*" + TypeIdent(b) };
        var args = new List<string>();
        int i = 0;
        foreach (var p in root.Parameters) { ps.Add("a" + i + ": " + ParamType(p)); args.Add("a" + i); i++; }
        f.Append("pub fn ").Append(name).Append('(').Append(string.Join(", ", ps)).Append(") E!").Append(RetType(root)).Append(" {\n");
        f.Append("    const o = this.?;\n    switch (o").Append(TidPath(b)).Append(") {\n");
        var groups = new Dictionary<IMethodSymbol, List<INamedTypeSymbol>>(SymbolEqualityComparer.Default);
        foreach (var d in Descendants(b).Where(x => !x.IsAbstract))
        {
            IMethodSymbol? impl = null;
            for (INamedTypeSymbol? x = d; x != null && impl == null; x = x.BaseType)
            {
                foreach (var cand in x.GetMembers(root.Name).OfType<IMethodSymbol>())
                {
                    if (cand.IsAbstract) continue;
                    if (SymbolEqualityComparer.Default.Equals(cand.OriginalDefinition, root) || (cand.IsOverride && SymbolEqualityComparer.Default.Equals(VRoot(cand), root)))
                    { impl = cand.OriginalDefinition; break; }
                }
                if (SymbolEqualityComparer.Default.Equals(x.OriginalDefinition, b)) break;
            }
            if (impl == null) continue;
            if (!groups.TryGetValue(impl, out var l)) groups[impl] = l = new List<INamedTypeSymbol>();
            l.Add(d);
        }
        foreach (var kv in groups)
        {
            var impl = kv.Key;
            var it = impl.ContainingType.OriginalDefinition;
            f.Append("        ").Append(string.Join(", ", kv.Value.Select(Tid))).Append(" => return ").Append(FuncName(impl)).Append('(')
             .Append(SymbolEqualityComparer.Default.Equals(it, b) ? "o" : Downcast("o", b, it));
            foreach (var a in args) f.Append(", ").Append(a);
            f.Append("),\n");
        }
        f.Append("        else => unreachable,\n    }\n}\n\n");
        funcs.Append(f);
        return name;
    }
}

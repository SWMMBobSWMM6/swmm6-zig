// ZigExpr.cs - C# expressions (Roslyn IOperation trees) to Zig expressions.
// Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Numerics;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.Operations;

public static partial class Cs2Zig
{
    static bool IsFloat(ITypeSymbol? t) => t != null && (t.SpecialType == SpecialType.System_Double || t.SpecialType == SpecialType.System_Single);
    static bool IsIntegral(ITypeSymbol? t) => t != null && t.SpecialType is SpecialType.System_Int32 or SpecialType.System_Int64 or SpecialType.System_UInt32 or SpecialType.System_UInt64 or SpecialType.System_Int16 or SpecialType.System_UInt16 or SpecialType.System_SByte or SpecialType.System_Byte or SpecialType.System_Char;
    static bool IsNumeric(ITypeSymbol? t) => IsFloat(t) || IsIntegral(t);
    static bool IsUnsigned(ITypeSymbol? t) => t != null && t.SpecialType is SpecialType.System_UInt32 or SpecialType.System_UInt64 or SpecialType.System_UInt16 or SpecialType.System_Byte or SpecialType.System_Char;
    static ITypeSymbol Under(ITypeSymbol t) => t.TypeKind == TypeKind.Enum ? ((INamedTypeSymbol)t).EnumUnderlyingType! : t;

    public sealed partial class Fn
    {
        readonly Stack<string> condAccess = new();

        /// <summary>The value of op, converted (as C# does at this point) to target if given.</summary>
        public string Value(IOperation op, ITypeSymbol? target)
        {
            var s = X(op);
            if (target != null && op.Type != null && !SymbolEqualityComparer.Default.Equals(op.Type, target))
                s = Conv(s, op.Type, target);
            return s;
        }

        string VarRef(ISymbol s)
        {
            if (captured.TryGetValue(s, out var f)) return "__c." + f + ".*";
            var n = names.TryGetValue(s, out var nn) ? nn : Todo("unknown variable " + s.Name);
            return refVars.Contains(s) || cells.Contains(s) ? n + ".*" : n;
        }

        string ThisRef() => inLambda ? (capturesThis ? "__c.this" : Todo("this in a lambda that does not capture it")) : "this";

        public string X(IOperation op)
        {
            if (op.ConstantValue.HasValue && !(op is IFieldReferenceOperation fr0 && fr0.Field.ContainingType.TypeKind == TypeKind.Enum && IsEngine(fr0.Field.ContainingType)))
                return Const(op.ConstantValue.Value, op.Type);
            switch (op)
            {
                case IConversionOperation c: return Conversion(c);
                case ILocalReferenceOperation l: return VarRef(l.Local);
                case IParameterReferenceOperation pr: return VarRef(pr.Parameter);
                case IInstanceReferenceOperation ir:
                    // base.M(): `this` seen as its base class
                    if (ir.Type is INamedTypeSymbol bt && IsEngine(bt) && !SymbolEqualityComparer.Default.Equals(bt.OriginalDefinition, cls.OriginalDefinition) && DerivesOrSame(cls, bt))
                        return Upcast(ThisRef(), cls, bt);
                    return ThisRef();
                case IFieldReferenceOperation f: return Field(f);
                case IPropertyReferenceOperation p: return Prop(p);
                case IArrayElementReferenceOperation ae:
                    if (ae.Indices.Length != 1) return Todo("multidimensional array element");
                    return Recv(ae.ArrayReference) + ".?[@intCast(" + X(ae.Indices[0]) + ")]";
                case IInvocationOperation inv: return Invoke(inv);
                case IObjectCreationOperation oc: return New(oc);
                case IArrayCreationOperation ac: return NewArray(ac);
                case IBinaryOperation b: return Binary(b);
                case IUnaryOperation u: return Unary(u);
                case IConditionalOperation c: return Ternary(c);
                case ISimpleAssignmentOperation a:
                    {
                        var bl = Fresh("b"); var v = Fresh("v");
                        if (IsCPtrElem(a.Target, out var pe, out var pi))
                            return bl + ": { const " + v + " = " + Value(a.Value, a.Target.Type) + "; rt.cset(" + pe + ", " + pi + ", " + v + "); break :" + bl + " " + v + "; }";
                        var ptr = Fresh("p");
                        return bl + ": { const " + ptr + " = " + Addr(a.Target) + "; const " + v + " = " + Value(a.Value, a.Target.Type) + "; " + ptr + ".* = " + v + "; break :" + bl + " " + v + "; }";
                    }
                case ICompoundAssignmentOperation ca:
                    {
                        var bl = Fresh("b"); var ptr = Fresh("p");
                        var tt = ca.Target.Type!;
                        string nv;
                        if (ca.OperatorMethod != null) nv = UserBinary(ca.OperatorMethod, ptr + ".*", X(ca.Value), tt, ca.Value.Type!);
                        else
                        {
                            bool conv = ca.InConversion.Exists && !ca.InConversion.IsIdentity || ca.OutConversion.Exists && !ca.OutConversion.IsIdentity;
                            var opT = ca.Value.Type!;
                            nv = conv ? Conv(ArithOp(ca.OperatorKind, Conv(ptr + ".*", tt, opT), X(ca.Value), opT), opT, tt) : ArithOp(ca.OperatorKind, ptr + ".*", X(ca.Value), tt);
                        }
                        return bl + ": { const " + ptr + " = " + Addr(ca.Target) + "; " + ptr + ".* = " + nv + "; break :" + bl + " " + ptr + ".*; }";
                    }
                case IIncrementOrDecrementOperation inc:
                    {
                        bool up = inc.Kind == OperationKind.Increment;
                        var bl = Fresh("b"); var ptr = Fresh("p"); var o = Fresh("o");
                        var t = inc.Target.Type!;
                        if (IsCPtrElem(inc.Target, out var pe, out var pi))
                        {
                            var cp = Fresh("cp"); var ck = Fresh("ck");
                            var nv0 = "rt.cget(" + cp + ", " + ck + ") " + (up ? "+%" : "-%") + " 1";
                            return bl + ": { const " + cp + " = " + pe + "; const " + ck + " = " + pi + "; const " + o + " = rt.cget(" + cp + ", " + ck + "); rt.cset(" + cp + ", " + ck + ", " + nv0 + "); break :" + bl + " " + (inc.IsPostfix ? o : "rt.cget(" + cp + ", " + ck + ")") + "; }";
                        }
                        string nv = inc.OperatorMethod != null ? RuntimeOpCall(inc.OperatorMethod, new[] { o }) : StepValue(o, t, up);
                        return bl + ": { const " + ptr + " = " + Addr(inc.Target) + "; const " + o + " = " + ptr + ".*; " + ptr + ".* = " + nv + "; break :" + bl + " " + (inc.IsPostfix ? o : ptr + ".*") + "; }";
                    }
                case IConditionalAccessOperation ca: return CondAccess(ca);
                case IConditionalAccessInstanceOperation: return condAccess.Count > 0 ? condAccess.Peek() : Todo("conditional access instance");
                case IAnonymousFunctionOperation af: return Lambda(af, null);
                case IDelegateCreationOperation dc: return DelegateCreation(dc);
                case IDefaultValueOperation dv: return Zero(dv.Type!);
                case ILiteralOperation lit: return Const(lit.ConstantValue.Value, lit.Type);
                case IIsTypeOperation it: return IsType(it.ValueOperand, it.TypeOperand);
                case ICoalesceOperation co: return "(" + X(co.Value) + " orelse " + Value(co.WhenNull, co.Type) + ")";
                case IParenthesizedOperation pp: return X(pp.Operand);
                case ISizeOfOperation so: return "@as(i32, @sizeOf(" + ZigType(so.TypeOperand) + "))";
                case IDiscardOperation: return "_";
                case IThrowOperation: return Todo("throw expression");
            }
            return Todo("expression " + op.Kind);
        }

        string Recv(IOperation inst) => X(inst);

        // ---- constants
        static string Const(object? v, ITypeSymbol? t)
        {
            if (v == null) return t != null ? Zero(t) : "null";
            switch (v)
            {
                case bool b: return b ? "true" : "false";
                case string s: return ZigStr(s);
                case char ch: return "@as(u16, " + (int)ch + ")";
                case double d: return t != null && t.SpecialType == SpecialType.System_Single ? FloatLit((float)d) : FloatLit(d);
                case float f: return t != null && t.SpecialType == SpecialType.System_Double ? FloatLit((double)f) : FloatLit(f);
            }
            var lit = IntLit(v);
            if (t == null) return lit;
            if (t.TypeKind == TypeKind.Enum)
            {
                var nt = (INamedTypeSymbol)t;
                if (IsEngine(nt))
                {
                    var mem = nt.GetMembers().OfType<IFieldSymbol>().FirstOrDefault(fm => fm.HasConstantValue && Equals(fm.ConstantValue, v));
                    if (mem != null) return TypeIdent(nt) + "__" + mem.Name.TrimStart('@');
                }
                return "@as(" + ZigType(t) + ", " + lit + ")";
            }
            if (IsFloat(t)) return t.SpecialType == SpecialType.System_Single ? FloatLit(Convert.ToSingle(v)) : FloatLit(Convert.ToDouble(v));
            return "@as(" + ZigType(t) + ", " + lit + ")";
        }

        /// <summary>A double literal Zig reads exactly: Zig reads a decimal literal to f128 and rounds that to f64,
        /// which can round twice, so the shortest decimal is written only when its distance from the double is
        /// far enough from half a unit in the last place; otherwise the exact hexadecimal form.</summary>
        static string FloatLit(double d)
        {
            long bits = BitConverter.DoubleToInt64Bits(d);
            if (double.IsNaN(d) || double.IsInfinity(d) || (d == 0 && bits != 0))
                return "@as(f64, @bitCast(@as(u64, 0x" + ((ulong)bits).ToString("x16") + ")))";
            var s = d.ToString("R", CultureInfo.InvariantCulture);
            if (!DecimalSafe(s, d, 53, (bits >> 52) & 0x7FF, bits & 0xFFFFFFFFFFFFFL, 1075))
                return "@as(f64, @bitCast(@as(u64, 0x" + ((ulong)bits).ToString("x16") + ")))";
            if (!s.Contains('.') && !s.Contains('E') && !s.Contains('e')) s += ".0";
            return "@as(f64, " + s.Replace("E", "e") + ")";
        }

        static string FloatLit(float f)
        {
            int bits = BitConverter.SingleToInt32Bits(f);
            if (float.IsNaN(f) || float.IsInfinity(f) || (f == 0 && bits != 0))
                return "@as(f32, @bitCast(@as(u32, 0x" + ((uint)bits).ToString("x8") + ")))";
            var s = f.ToString("R", CultureInfo.InvariantCulture);
            if (!DecimalSafe(s, f, 24, (bits >> 23) & 0xFF, bits & 0x7FFFFF, 150))
                return "@as(f32, @bitCast(@as(u32, 0x" + ((uint)bits).ToString("x8") + ")))";
            if (!s.Contains('.') && !s.Contains('E') && !s.Contains('e')) s += ".0";
            return "@as(f32, " + s.Replace("E", "e") + ")";
        }

        /// <summary>The decimal s (the shortest round trip of the binary value) is within ulp/2 - ulp*2^-(113-p) of it, so
        /// rounding s to f128 and then to p bits gives the value back.</summary>
        static bool DecimalSafe(string s, double val, int p, long bexp, long frac, int bias)
        {
            // the binary value m * 2^e, its ulp 2^e (a subnormal has e = 1 - bias)
            BigInteger m = bexp == 0 ? frac : frac | (1L << (p - 1));
            int e = bexp == 0 ? 1 - bias : (int)bexp - bias;
            // the decimal N / D
            var t = s.StartsWith("-") ? s.Substring(1) : s;
            int exp10 = 0;
            var ei = t.IndexOfAny(new[] { 'E', 'e' });
            if (ei >= 0) { exp10 = int.Parse(t.Substring(ei + 1), CultureInfo.InvariantCulture); t = t.Substring(0, ei); }
            var dot = t.IndexOf('.');
            if (dot >= 0) { exp10 -= t.Length - dot - 1; t = t.Remove(dot, 1); }
            var N = BigInteger.Parse(t, CultureInfo.InvariantCulture);
            BigInteger D = 1;
            if (exp10 >= 0) N *= BigInteger.Pow(10, exp10); else D = BigInteger.Pow(10, -exp10);
            // safe when |N/D - m 2^e| * 2^K < 2^e (2^(K-1) - 1), K = 113 - p + 1 (f128's rounding error is below 2^(e-K))
            int K = 113 - p + 1;
            BigInteger lhs, rhs;
            if (e >= 0) { lhs = BigInteger.Abs(N - D * m * BigInteger.Pow(2, e)); rhs = D * BigInteger.Pow(2, e) * (BigInteger.Pow(2, K - 1) - 1); }
            else { lhs = BigInteger.Abs(N * BigInteger.Pow(2, -e) - D * m); rhs = D * (BigInteger.Pow(2, K - 1) - 1); }
            return lhs * BigInteger.Pow(2, K) < rhs;
        }

        static string ZigStr(string s)
        {
            var sb = new StringBuilder("\"");
            foreach (var ch in s)
            {
                int c = ch;
                if (c > 255) Todo("non-Latin-1 character in a string");
                if (c == '"') sb.Append("\\\"");
                else if (c == '\\') sb.Append("\\\\");
                else if (c >= 32 && c < 127) sb.Append(ch);
                else sb.Append("\\x").Append(c.ToString("x2"));
            }
            return sb.Append('"').ToString();
        }

        public static string Zero(ITypeSymbol t)
        {
            if (t.SpecialType == SpecialType.System_Boolean) return "false";
            if (IsNumeric(t)) return "@as(" + ZigType(t) + ", 0)";
            if (t.TypeKind == TypeKind.Enum) return "@as(" + ZigType(t) + ", 0)";
            var z = ZigType(t);
            if (z.StartsWith("?") || z == "rt.Obj") return "null";
            return "std.mem.zeroes(" + z + ")";
        }

        // ---- conversions
        string Conversion(IConversionOperation c)
        {
            var from = c.Operand.Type;
            var to = c.Type!;
            if (c.OperatorMethod != null) return RuntimeConvOp(c.OperatorMethod, c.Operand, to);
            if (c.Operand is IAnonymousFunctionOperation af) return Lambda(af, to);
            if (c.Operand is IDelegateCreationOperation dc0 && to.TypeKind == TypeKind.Delegate) return DelegateCreation(dc0, to);
            if (from == null)
            {
                if (c.Operand is ILiteralOperation || c.Operand is IDefaultValueOperation) return Zero(to);
                if (c.Operand is IDelegateCreationOperation dc) return DelegateCreation(dc, to);
                return X(c.Operand);
            }
            return Conv(X(c.Operand), from, to);
        }

        string Conv(string s, ITypeSymbol from, ITypeSymbol to)
        {
            if (SymbolEqualityComparer.Default.Equals(from, to)) return s;
            if (IsNumeric(to) || to.TypeKind == TypeKind.Enum)
            {
                var tu = Under(to);
                var tz = ZigType(to);
                if (IsFloat(from) && IsIntegral(tu)) return "rt.f2" + ZigType(tu) + "(" + s + ")";
                if (IsFloat(from) && IsFloat(tu))
                    return tu.SpecialType == SpecialType.System_Single && from.SpecialType == SpecialType.System_Double ? "@as(f32, @floatCast(" + s + "))" : "@as(" + tz + ", " + s + ")";
                if ((IsIntegral(from) || from.TypeKind == TypeKind.Enum) && IsFloat(tu)) return "@as(" + tz + ", @floatFromInt(" + s + "))";
                if (IsIntegral(from) || from.TypeKind == TypeKind.Enum)
                {
                    if (ZigType(Under(from)) == ZigType(tu)) return s;
                    return "rt.cv(" + tz + ", " + s + ")";
                }
                if (from.SpecialType == SpecialType.System_Object) return "rt.unbox(" + tz + ", " + s + ")";
                return Todo("conversion " + from.ToDisplayString() + " -> " + to.ToDisplayString());
            }
            if (from.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T || to.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T) return s;
            if (IsExceptionType(from) && IsExceptionType(to) && !IsEngine(from) && !IsEngine(to)) return s;
            if (to.SpecialType == SpecialType.System_Object || (to is INamedTypeSymbol tdi && IsSystem(tdi) && tdi.Name == "IDisposable"))
            {
                if (from.SpecialType == SpecialType.System_Object) return s;
                if (from is INamedTypeSymbol fe && IsEngine(fe) && fe.TypeKind == TypeKind.Class)
                {
                    var root = fe.OriginalDefinition;
                    while (root.BaseType != null && IsEngine(root.BaseType)) root = root.BaseType.OriginalDefinition;
                    return "rt.toObj(" + (SymbolEqualityComparer.Default.Equals(root, fe.OriginalDefinition) ? s : Upcast(s, fe, root)) + ")";
                }
                var fz = ZigType(from);
                if (fz.StartsWith("?*")) return "rt.toObj(" + s + ")";
                return "rt.box(" + fz + ", " + s + ")";
            }
            if (from.SpecialType == SpecialType.System_Object)
            {
                if (to is INamedTypeSymbol te && IsEngine(te) && te.TypeKind == TypeKind.Class)
                {
                    var root = te.OriginalDefinition;
                    while (root.BaseType != null && IsEngine(root.BaseType)) root = root.BaseType.OriginalDefinition;
                    var r = "rt.fromObj(" + TypeIdent(root) + ", " + s + ")";
                    return SymbolEqualityComparer.Default.Equals(root, te.OriginalDefinition) ? r : DowncastOpt(r, root, te);
                }
                var tz = ZigType(to);
                if (tz.StartsWith("?*")) return "rt.fromObj(" + tz.Substring(2) + ", " + s + ")";
                return "rt.unbox(" + tz + ", " + s + ")";
            }
            if (from is INamedTypeSymbol fn && to is INamedTypeSymbol tn)
            {
                if (IsEngine(fn) && IsEngine(tn))
                {
                    if (DerivesOrSame(fn, tn)) return Upcast(s, fn, tn);
                    if (DerivesOrSame(tn, fn)) return DowncastOpt(s, fn, tn);
                }
                if (IsEngine(fn) && IsExceptionType(tn) && !IsEngine(tn)) return ToRuntimeBase(s, fn);
                if (fn.TypeKind == TypeKind.Delegate && tn.TypeKind == TypeKind.Delegate)
                {
                    if (ZigType(fn) == ZigType(tn)) return s;
                    return Todo("delegate conversion " + fn.ToDisplayString() + " -> " + tn.ToDisplayString());
                }
                if (IsRuntime(fn) && IsRuntime(tn) && ZigType(fn) == ZigType(tn)) return s;
                if (SymbolEqualityComparer.Default.Equals(fn.OriginalDefinition, tn.OriginalDefinition) && ZigType(fn) == ZigType(tn)) return s;
            }
            if (from is IArrayTypeSymbol && to is IArrayTypeSymbol && ZigType(from) == ZigType(to)) return s;
            return Todo("conversion " + from.ToDisplayString() + " -> " + to.ToDisplayString());
        }

        string Upcast(string s, INamedTypeSymbol d, INamedTypeSymbol b)
        {
            var u = Fresh("u");
            return "@as(?*" + TypeIdent(b) + ", if (" + s + ") |" + u + "| &" + u + BasePath(d, b) + " else null)";
        }

        string DowncastOpt(string s, INamedTypeSymbol b, INamedTypeSymbol d)
        {
            var u = Fresh("u");
            return "@as(?*" + TypeIdent(d) + ", if (" + s + ") |" + u + "| " + Downcast(u, b, d) + " else null)";
        }

        string RuntimeConvOp(IMethodSymbol op, IOperation operand, ITypeSymbol to)
        {
            var t = op.ContainingType;
            var tn = StripArity(t.Name);
            var arg = X(operand);
            var pt = op.Parameters[0].Type;
            // pointers are Zig pointers: a char* from a byte* or sbyte*, a double* from a vector iterator
            if (tn == "CPtr" && pt is INamedTypeSymbol pn && StripArity(pn.Name) == "Ptr") return "rt.toCPtr(" + arg + ")";
            if (tn == "Ptr" && pt is INamedTypeSymbol pn2 && StripArity(pn2.Name) == "Iter") return "rt.iterPtr(" + arg + ")";
            if (tn == "Str" && pt is INamedTypeSymbol pn3 && pn3.Name == "CPtr") { Use("conversion " + op.ToDisplayString(), "rt.Str.fromCPtr"); return Call("rt.Str.fromCPtr(" + arg + ")"); }
            return Todo("runtime conversion " + op.ToDisplayString());
        }

        // ---- fields and properties
        string Field(IFieldReferenceOperation f)
        {
            var fs = f.Field;
            if (fs.ContainingType.TypeKind == TypeKind.Enum)
            {
                if (IsEngine(fs.ContainingType)) return TypeIdent(fs.ContainingType) + "__" + fs.Name.TrimStart('@');
                return Const(fs.ConstantValue, fs.Type);
            }
            if (IsRuntime(fs))
            {
                if (fs.IsStatic || fs.IsConst)
                {
                    var n = "rt." + RuntimeTypeName(fs.ContainingType) + "." + Id(fs.Name);
                    Use("static field " + fs.OriginalDefinition.ToDisplayString(), n);
                    return n;
                }
                var it = f.Instance!.Type!;
                Use("field " + fs.OriginalDefinition.ToDisplayString(), Id(fs.Name));
                return Recv(f.Instance!) + (it.TypeKind == TypeKind.Struct ? "." : ".?.") + Id(fs.Name);
            }
            if (fs.IsStatic || fs.IsConst) return StaticFieldName(fs);
            var r = Recv(f.Instance!);
            var rt0 = f.Instance!.Type as INamedTypeSymbol;
            var path = rt0 != null && IsEngine(rt0) ? BasePath(rt0, fs.ContainingType) : "";
            return r + ".?" + path + "." + FieldIdent(fs);
        }

        bool IsCPtrElem(IOperation t, out string ptr, out string idx)
        {
            ptr = idx = "";
            if (t is IPropertyReferenceOperation p && p.Property.IsIndexer && p.Property.ContainingType.Name == "CPtr" && IsRuntime(p.Property))
            {
                ptr = Recv(p.Instance!);
                idx = X(p.Arguments[0].Value);
                return true;
            }
            return false;
        }

        /// <summary>A runtime property or indexer. Pointer-like values (CPtr, Ptr, Iter) are Zig pointers, so their
        /// properties are written out; vector and string indexers index the storage; the rest are methods p_Name of
        /// the runtime type (returning a pointer for a ref property), which cannot fail.</summary>
        string Prop(IPropertyReferenceOperation p, bool addr = false)
        {
            var ps = p.Property;
            if (IsSystem(ps) && ps.Name == "Length") return "@as(i32, @intCast(" + Recv(p.Instance!) + ".?.len))";
            if (!IsRuntime(ps)) return Todo((IsSystem(ps) ? "system" : "engine") + " property " + ps.ContainingType.Name + "." + ps.Name);
            var tn = StripArity(ps.ContainingType.Name);
            if (ps.IsStatic)
            {
                var n = "rt." + RuntimeTypeName(ps.ContainingType) + ".p_" + ps.Name;
                Use("static property " + ps.ToDisplayString(), n);
                return n + "()";
            }
            var r = Recv(p.Instance!);
            var args = p.Arguments.Select(a => X(a.Value)).ToList();
            string place;
            if (tn == "Ptr" && ps.Name == "Deref") place = r + ".?[0]";
            else if ((tn == "Ptr" || tn == "CPtr") && ps.Name == "IsNull") return "(" + r + " == null)";
            else if (tn == "Ptr" && ps.IsIndexer) place = "rt.pat(" + r + ", " + args[0] + ").*";
            else if (tn == "CPtr" && ps.IsIndexer) return "rt.cget(" + r + ", " + args[0] + ")";
            else if (tn == "Vec" && ps.IsIndexer) place = r + ".?.a.?[@intCast(" + args[0] + ")]";
            else if (tn == "Str" && ps.IsIndexer) place = r + ".?.b.?[@intCast(" + args[0] + ")]";
            else
            {
                var sfx = ps.IsIndexer && ps.ContainingType.GetMembers().OfType<IPropertySymbol>().Count(x => x.IsIndexer) > 1 ? "_" + ShortType(ps.OriginalDefinition.Parameters[0].Type) : "";
                var mname = "p_" + (ps.IsIndexer ? "At" : ps.Name) + sfx;
                Use("property " + ps.ContainingType.OriginalDefinition.ToDisplayString() + "." + ps.Name, mname + (ps.RefKind != RefKind.None ? " (pointer)" : ""));
                var recv = p.Instance!.Type!.TypeKind == TypeKind.Struct ? r : r + ".?";
                var call = recv + "." + mname + "(" + string.Join(", ", args) + ")";
                if (ps.RefKind == RefKind.None) return call;
                return addr ? call : call + ".*";
            }
            if (addr) return "&" + place;
            return place;
        }

        string Place(IOperation op) => X(op);

        /// <summary>A Zig pointer to the location op names (a ref argument, a ref local, &x).</summary>
        public string Addr(IOperation op)
        {
            switch (op)
            {
                case ILocalReferenceOperation l: return AddrOf(l.Local);
                case IParameterReferenceOperation p: return AddrOf(p.Parameter);
                case IFieldReferenceOperation f: return "&" + Field(f);
                case IArrayElementReferenceOperation ae: return "&" + X(ae);
                case IPropertyReferenceOperation pr:
                    if (pr.Property.RefKind != RefKind.None || pr.Property.IsIndexer) return Prop(pr, true);
                    return Todo("address of a non-ref property " + pr.Property.Name);
                case IInvocationOperation inv when inv.TargetMethod.RefKind != RefKind.None:
                    return Invoke(inv, true);
                case IConditionalOperation c when c.IsRef:
                    return "(if (" + X(c.Condition) + ") " + Addr(c.WhenTrue) + " else " + Addr(c.WhenFalse!) + ")";
                case IConversionOperation cv when cv.Conversion.IsIdentity: return Addr(cv.Operand);
                case IParenthesizedOperation pp: return Addr(pp.Operand);
                case IConditionalAccessInstanceOperation: return Todo("address of a conditional access");
            }
            return Todo("address of " + op.Kind);
        }

        string AddrOf(ISymbol s)
        {
            if (captured.TryGetValue(s, out var f)) return "__c." + f;
            var n = names.TryGetValue(s, out var nn) ? nn : Todo("unknown variable " + s.Name);
            return refVars.Contains(s) || cells.Contains(s) ? n : "&" + n;
        }

        // ---- calls
        List<string> ArgList(IMethodSymbol m, IEnumerable<IArgumentOperation> args, bool runtime)
        {
            var outv = new List<string>();
            foreach (var a in args.OrderBy(a => a.Parameter?.Ordinal ?? 0))
            {
                var prm = a.Parameter!;
                if (a.ArgumentKind == ArgumentKind.ParamArray)
                {
                    // a params array: a Zig tuple of the values as they are (printf's arguments)
                    if (a.Value is IArrayCreationOperation ac && ac.Initializer != null)
                        outv.Add(".{ " + string.Join(", ", ac.Initializer.ElementValues.Select(ParamsElem)) + " }");
                    else outv.Add(Todo("params array passed as an array"));
                    continue;
                }
                if (prm.RefKind != RefKind.None) outv.Add(Addr(a.Value));
                else if (runtime && prm.Type.SpecialType == SpecialType.System_Object) outv.Add(Unboxed(a.Value));
                else outv.Add(Value(a.Value, prm.Type));
            }
            return outv;
        }

        string Args(IMethodSymbol m, IEnumerable<IArgumentOperation> args, bool runtime = false) => string.Join(", ", ArgList(m, args, runtime));

        /// <summary>A value passed as object to the runtime: the value itself (the runtime takes anytype).</summary>
        string Unboxed(IOperation v)
        {
            while (v is IConversionOperation cv && cv.Type!.SpecialType == SpecialType.System_Object && cv.OperatorMethod == null) v = cv.Operand;
            if (v.Type == null) return "null";
            return X(v);
        }

        /// <summary>An element of a params array: unboxed; an sscanf target R.RefI(x => v = x) is the address of v.</summary>
        string ParamsElem(IOperation e)
        {
            while (e is IConversionOperation cv && cv.OperatorMethod == null && (cv.Type!.SpecialType == SpecialType.System_Object || cv.IsImplicit)) e = cv.Operand;
            if (e is IInvocationOperation iv && IsRuntime(iv.TargetMethod) && iv.TargetMethod.ContainingType.Name == "R" && iv.TargetMethod.Name.StartsWith("Ref") && iv.TargetMethod.Name.Length == 4)
            {
                var lam = iv.Arguments[0].Value;
                while (lam is IDelegateCreationOperation dc) lam = dc.Target;
                if (lam is IAnonymousFunctionOperation af)
                {
                    var ops = af.Body.Operations;
                    IOperation? st = ops.Length >= 1 ? ops[0] : null;
                    if (st is IExpressionStatementOperation es && es.Operation is ISimpleAssignmentOperation sa) return Addr(sa.Target);
                    if (st is IReturnOperation ro && ro.ReturnedValue is ISimpleAssignmentOperation sa2) return Addr(sa2.Target);
                }
                return Todo("sscanf target");
            }
            if (e is IFieldReferenceOperation fr && IsRuntime(fr.Field) && fr.Field.Name == "Slot") return "rt.R.Slot";
            if (e.Type == null) return "null";
            return X(e);
        }

        string Invoke(IInvocationOperation inv, bool addr = false)
        {
            var m = inv.TargetMethod;
            string call;
            if (m.MethodKind == MethodKind.DelegateInvoke)
                call = Call(Recv(inv.Instance!) + ".call(" + Args(m, inv.Arguments) + ")");
            else if (IsRuntime(m) || IsSystem(m))
            {
                var special = SpecialRuntimeCall(inv);
                if (special != null) return special;
                call = RuntimeCall(m, inv.Instance, inv.Arguments);
            }
            else if (m.IsStatic)
                call = Call(FuncName(m) + "(" + Args(m, inv.Arguments) + ")");
            else
            {
                var recvT = inv.Instance!.Type as INamedTypeSymbol;
                var r = Recv(inv.Instance!);
                var decl = m.ContainingType.OriginalDefinition;
                var a = Args(m, inv.Arguments);
                if (inv.IsVirtual && (m.IsVirtual || m.IsAbstract || m.IsOverride) && tids.ContainsKey(VRoot(m).ContainingType.OriginalDefinition))
                {
                    var root = VRoot(m).ContainingType.OriginalDefinition;
                    var rr = recvT != null && !SymbolEqualityComparer.Default.Equals(recvT.OriginalDefinition, root) ? Upcast(r, recvT, root) : r;
                    call = Call(VDispatch(m) + "(" + rr + (a.Length > 0 ? ", " + a : "") + ")");
                }
                else
                {
                    var rr = recvT != null && IsEngine(recvT) && !SymbolEqualityComparer.Default.Equals(recvT.OriginalDefinition, decl) ? Upcast(r, recvT, decl) : r;
                    call = Call(FuncName(m) + "(" + rr + (a.Length > 0 ? ", " + a : "") + ")");
                }
            }
            if (m.RefKind != RefKind.None) return addr ? call : call + ".*";
            return call;
        }

        /// <summary>Runtime calls that are not calls in Zig: copy-backs of boxed out-parameters, sscanf's slots,
        /// char* literals, pointer helpers.</summary>
        string? SpecialRuntimeCall(IInvocationOperation inv)
        {
            var m = inv.TargetMethod;
            var tn = StripArity(m.ContainingType.Name);
            var args = inv.Arguments.OrderBy(a => a.Parameter!.Ordinal).ToList();
            if (tn == "Mv" && m.Name == "Back")
            {
                // Back(v, ref x, box): v, then x = box[0]
                var bl = Fresh("b"); var r = Fresh("r");
                var v = X(args[0].Value);
                return bl + ": { const " + r + " = " + v + "; " + Place(args[1].Value) + " = " + X(args[2].Value) + ".?[0]; break :" + bl + " " + r + "; }";
            }
            if (tn == "R" && m.Name == "Back")
            {
                // R.Back(sscanf(..., R.Slot, ...), ref a, ...): the slots are the ref arguments' addresses
                var inner = args[0].Value;
                while (inner is IConversionOperation cv) inner = cv.Operand;
                if (inner is not IInvocationOperation sc || sc.TargetMethod.Name != "sscanf") return Todo("R.Back of " + inner.Kind);
                var refs = args.Skip(1).Select(a => Addr(a.Value)).ToList();
                var s = Invoke(sc);
                int k = 0;
                while (s.Contains("rt.R.Slot") && k < refs.Count) { var at = s.IndexOf("rt.R.Slot"); s = s.Substring(0, at) + refs[k++] + s.Substring(at + 9); }
                return s;
            }
            if (tn == "R" && m.Name == "Lit" && args.Count == 1)
            {
                var a = args[0].Value;
                if (a.ConstantValue.HasValue && a.ConstantValue.Value is string str) return "rt.lit(" + ZigStr(str) + ")";
                return Call("rt.R.LitDyn(" + X(a) + ")");
            }
            if (tn == "Std" && m.Name == "Nop") return "@as(i32, 0)";
            if (tn == "Dbg" && m.Name == "Caught") return "{}";
            if (tn == "Box" && m.Name == "Of")
            {
                // Box<T>.Of(() => ref x): a box holding the address of x
                var lam = args[0].Value;
                while (lam is IDelegateCreationOperation dc) lam = dc.Target;
                while (lam is IConversionOperation cv2) lam = cv2.Operand;
                if (lam is IAnonymousFunctionOperation af && af.Body.Operations.Length == 1 && af.Body.Operations[0] is IReturnOperation ro && ro.ReturnedValue != null)
                    return Call("rt.Box(" + ZigType(((INamedTypeSymbol)m.ContainingType).TypeArguments[0]) + ").of(" + Addr(ro.ReturnedValue) + ")");
                return Todo("Box.Of of " + lam.Kind);
            }
            if (tn == "Dtor" && m.Name == "Run")
            {
                var v = args[0].Value;
                while (v is IConversionOperation cv && cv.Type!.SpecialType == SpecialType.System_Object) v = cv.Operand;
                if (v.Type is INamedTypeSymbol et && IsEngine(et))
                {
                    if (!NeedsDisposeDispatch(et)) return "{}";
                    return Call(TypeIdent(et) + ".__dispose(" + X(v) + ")");
                }
                return Call("rt.Dtor.Run(" + (v.Type == null ? "null" : X(v)) + ")");
            }
            if (tn == "Mv" && m.Name == "Delete")
            {
                var v = args[0].Value;
                while (v is IConversionOperation cv && cv.Type!.SpecialType == SpecialType.System_Object) v = cv.Operand;
                if (v.Type is INamedTypeSymbol et && IsEngine(et))
                {
                    if (!NeedsDisposeDispatch(et)) return "{}";
                    return Call(TypeIdent(et) + ".__dispose(" + X(v) + ")");
                }
                return Call("rt.Dtor.Run(" + (v.Type == null ? "null" : X(v)) + ")");
            }
            return null;
        }

        string RuntimeCall(IMethodSymbol m, IOperation? inst, IEnumerable<IArgumentOperation> argOps)
        {
            var t = m.ContainingType;
            if (IsSystem(m)) return SystemCall(m, inst, argOps);
            var tn = StripArity(t.Name);
            // a runtime value type's Clone is the copy C# makes of a struct
            if (m.Name == "Clone" && !m.IsStatic && t.TypeKind == TypeKind.Struct && m.Parameters.Length == 0) return X(inst!);
            var overloads = t.GetMembers(m.Name).OfType<IMethodSymbol>().Count();
            var sfx = overloads > 1 ? "_" + string.Join("_", m.OriginalDefinition.Parameters.Select(p => ShortType(p.Type) + (p.RefKind != RefKind.None ? "r" : ""))) : "";
            var name = Id(m.Name) + sfx;
            var targs = m.IsGenericMethod ? m.TypeArguments.Select(ZigType).ToList() : new List<string>();
            var args = ArgList(m, argOps, true);
            var all = string.Join(", ", targs.Concat(args));
            string call;
            if (m.IsStatic)
            {
                var n = "rt." + RuntimeTypeName(t) + "." + name;
                Use("static " + m.OriginalDefinition.ToDisplayString(), "rt." + StripArity(t.Name) + "." + name);
                call = n + "(" + all + ")";
            }
            else
            {
                Use("method " + m.OriginalDefinition.ToDisplayString(), name);
                var r = Recv(inst!);
                var recv = inst!.Type!.TypeKind == TypeKind.Struct ? r : r + ".?";
                call = recv + "." + name + "(" + all + ")";
            }
            return Call(call);
        }

        string SystemCall(IMethodSymbol m, IOperation? inst, IEnumerable<IArgumentOperation> argOps)
        {
            var t = m.ContainingType.Name;
            var args = ArgList(m, argOps, false);
            var a = string.Join(", ", args);
            if (t == "Math" || t == "MathF")
            {
                var n = "rt.Math." + m.Name + (m.Parameters.Length > 0 ? "_" + ShortType(m.Parameters[0].Type) : "");
                Use("System.Math." + m.Name + "(" + string.Join(",", m.Parameters.Select(p => p.Type.Name)) + ")", n);
                return n + "(" + a + ")";
            }
            if (t == "Object" && m.Name == "ReferenceEquals") return "(" + args[0] + " == " + args[1] + ")";
            if (t == "Double" && m.Name == "IsNaN") return "std.math.isNan(" + a + ")";
            if (t == "Double" && m.Name == "IsFinite") return "std.math.isFinite(" + a + ")";
            if (t == "Double" && m.Name == "IsInfinity") return "std.math.isInf(" + a + ")";
            if (t == "Double" && m.Name == "IsPositiveInfinity") return "std.math.isPositiveInf(" + a + ")";
            if (t == "Double" && m.Name == "IsNegativeInfinity") return "std.math.isNegativeInf(" + a + ")";
            if (t == "Double" && m.Name == "IsNegative") return "std.math.signbit(" + a + ")";
            if (t == "BitConverter") { var n = "rt.BitConverter." + m.Name; Use("System.BitConverter." + m.Name, n); return n + "(" + a + ")"; }
            if (t == "File" && m.Name == "Exists") return Call("rt.File.Exists(" + a + ")");
            if (t == "Array" && m.Name == "Fill") return Call("rt.Array.Fill(" + a + ")");
            return Todo("system call " + m.ContainingType.Name + "." + m.Name);
        }

        string New(IObjectCreationOperation oc)
        {
            var t = (INamedTypeSymbol)oc.Type!;
            var c = oc.Constructor!;
            string e;
            if (t.TypeKind == TypeKind.Delegate) return Todo("delegate construction");
            if (IsEngine(t))
            {
                var tn = TypeIdent(t);
                if (c.Parameters.Length == 1 && c.Parameters[0].Type.Name == "Raw") e = Call(tn + "__raw()");
                else if (c.Parameters.Length == 0) e = Call(tn + "__new()");
                else return Todo("engine constructor with arguments");
            }
            else if (IsRuntime(t))
            {
                var tn = StripArity(t.Name);
                var args = oc.Arguments.OrderBy(a => a.Parameter!.Ordinal).ToList();
                if (tn == "Ptr" && args.Count == 2 && args[1].Value.Type?.TypeKind != TypeKind.Delegate && args[0].Value.Type?.SpecialType != SpecialType.System_Object)
                    e = "rt.arrPtr(" + X(args[0].Value) + ", " + Value(args[1].Value, args[1].Parameter!.Type) + ")";
                else if (tn == "Ptr" && args.Count == 2)
                    e = FieldPtr(args[0].Value, args[1].Value, ((INamedTypeSymbol)t).TypeArguments[0]);
                else if (IsExceptionType(t))
                {
                    var k = runtimeExcKinds.TryGetValue(tn, out var kk) ? kk : Todo("exception kind " + tn) is var _ ? 0 : 0;
                    var msg = args.Count > 0 ? args[0].Value : null;
                    if (msg == null) e = Call("rt.CppException.make(" + k + ", null)");
                    else if (msg.Type!.SpecialType == SpecialType.System_String) e = Call("rt.CppException.makeLit(" + k + ", " + X(msg) + ")");
                    else e = Call("rt.CppException.make(" + k + ", " + Value(msg, args[0].Parameter!.Type) + ")");
                }
                else
                {
                    var ctors = t.InstanceConstructors.Length;
                    var sfx = ctors > 1 && c.Parameters.Length > 0 ? "_" + string.Join("_", c.OriginalDefinition.Parameters.Select(p => ShortType(p.Type))) : "";
                    var n = "rt." + RuntimeTypeName(t) + ".new" + sfx;
                    Use("new " + c.OriginalDefinition.ToDisplayString(), "new" + sfx);
                    e = Call(n + "(" + Args(c, oc.Arguments, true) + ")");
                }
            }
            else if (IsSystem(t))
            {
                if (IsExceptionType(t))
                {
                    var k = runtimeExcKinds.TryGetValue(t.Name, out var kk) ? kk : 100;
                    e = Call("rt.CppException.makeLit(" + k + ", " + (oc.Arguments.Length > 0 ? X(oc.Arguments[0].Value) : "\"\"") + ")");
                }
                else return Todo("new " + t.ToDisplayString());
            }
            else return Todo("new " + t.ToDisplayString());
            if (oc.Initializer == null || oc.Initializer.Initializers.Length == 0) return e;
            // new X() { a = 1, b = 2 }
            var bl = Fresh("b"); var o = Fresh("o");
            var sb = new StringBuilder(bl + ": { const " + o + " = " + e + "; ");
            foreach (var init in oc.Initializer.Initializers)
            {
                if (init is ISimpleAssignmentOperation a && a.Target is IFieldReferenceOperation f)
                {
                    var v = Value(a.Value, a.Target.Type);
                    var fname = IsRuntime(f.Field) ? Id(f.Field.Name) : FieldIdent(f.Field);
                    var path = IsEngine(t) ? BasePath(t, f.Field.ContainingType) : "";
                    sb.Append(o).Append(t.TypeKind == TypeKind.Struct ? "" : ".?").Append(path).Append('.').Append(fname).Append(" = ").Append(v).Append("; ");
                }
                else Todo("object initializer " + init.Kind);
            }
            return sb.Append("break :").Append(bl).Append(' ').Append(o).Append("; }").ToString();
        }

        /// <summary>new Ptr&lt;T&gt;(obj, (object o) =&gt; ref ((C)o).f): the address of that field of obj.</summary>
        string FieldPtr(IOperation obj, IOperation getter, ITypeSymbol elem)
        {
            var lam = getter;
            while (lam is IDelegateCreationOperation dc) lam = dc.Target;
            while (lam is IConversionOperation cv) lam = cv.Operand;
            if (lam is not IAnonymousFunctionOperation af || af.Body.Operations.Length != 1 || af.Body.Operations[0] is not IReturnOperation ro || ro.ReturnedValue == null)
                return Todo("field pointer of " + lam.Kind);
            var prm = af.Symbol.Parameters[0];
            var bl = Fresh("b"); var on = Fresh("ob");
            used.Add(on);
            names[prm] = on;
            var ot = obj.Type;
            string objv = ot == null ? "null" : X(obj);
            if (ot != null && ot.SpecialType != SpecialType.System_Object) objv = Conv(objv, ot, comp.GetSpecialType(SpecialType.System_Object));
            var a = Addr(ro.ReturnedValue);
            return bl + ": { const " + on + ": rt.Obj = " + objv + "; _ = &" + on + "; break :" + bl + " @as(?[*]" + ZigType(elem) + ", @ptrCast(" + a + ")); }";
        }

        string NewArray(IArrayCreationOperation ac)
        {
            var at = (IArrayTypeSymbol)ac.Type!;
            var et = ZigType(at.ElementType);
            if (ac.Initializer != null)
                return "rt.arrOf(" + et + ", &[_]" + et + "{ " + string.Join(", ", ac.Initializer.ElementValues.Select(v => Value(v, at.ElementType))) + " })";
            return "rt.newArr(" + et + ", " + X(ac.DimensionSizes[0]) + ")";
        }

        // ---- operators
        string ArithOp(BinaryOperatorKind k, string l, string r, ITypeSymbol t)
        {
            t = Under(t);
            bool fl = IsFloat(t);
            bool un = IsUnsigned(t);
            switch (k)
            {
                case BinaryOperatorKind.Add: return "(" + l + (fl ? " + " : " +% ") + r + ")";
                case BinaryOperatorKind.Subtract: return "(" + l + (fl ? " - " : " -% ") + r + ")";
                case BinaryOperatorKind.Multiply: return "(" + l + (fl ? " * " : " *% ") + r + ")";
                case BinaryOperatorKind.Divide: return fl || un ? "(" + l + " / " + r + ")" : "@divTrunc(" + l + ", " + r + ")";
                case BinaryOperatorKind.Remainder: return fl ? "rt.Math.fmod(" + l + ", " + r + ")" : un ? "(" + l + " % " + r + ")" : "@rem(" + l + ", " + r + ")";
                case BinaryOperatorKind.LeftShift: return "rt.shl(" + l + ", " + r + ")";
                case BinaryOperatorKind.RightShift: return "rt.shr(" + l + ", " + r + ")";
                case BinaryOperatorKind.UnsignedRightShift: return "rt.ushr(" + l + ", " + r + ")";
                case BinaryOperatorKind.And: return t.SpecialType == SpecialType.System_Boolean ? "rt.band(" + l + ", " + r + ")" : "(" + l + " & " + r + ")";
                case BinaryOperatorKind.Or: return t.SpecialType == SpecialType.System_Boolean ? "rt.bor(" + l + ", " + r + ")" : "(" + l + " | " + r + ")";
                case BinaryOperatorKind.ExclusiveOr: return t.SpecialType == SpecialType.System_Boolean ? "(" + l + " != " + r + ")" : "(" + l + " ^ " + r + ")";
                case BinaryOperatorKind.ConditionalAnd: return "(" + l + " and " + r + ")";
                case BinaryOperatorKind.ConditionalOr: return "(" + l + " or " + r + ")";
                case BinaryOperatorKind.Equals: return "(" + l + " == " + r + ")";
                case BinaryOperatorKind.NotEquals: return "(" + l + " != " + r + ")";
                case BinaryOperatorKind.LessThan: return "(" + l + " < " + r + ")";
                case BinaryOperatorKind.LessThanOrEqual: return "(" + l + " <= " + r + ")";
                case BinaryOperatorKind.GreaterThan: return "(" + l + " > " + r + ")";
                case BinaryOperatorKind.GreaterThanOrEqual: return "(" + l + " >= " + r + ")";
            }
            return Todo("operator " + k);
        }

        string Binary(IBinaryOperation b)
        {
            if (b.OperatorMethod != null) return UserBinary(b.OperatorMethod, X(b.LeftOperand), X(b.RightOperand), b.LeftOperand.Type!, b.RightOperand.Type!);
            var lt = b.LeftOperand.Type;
            var rtp = b.RightOperand.Type;
            // a delegate compared with null
            if (b.OperatorKind is BinaryOperatorKind.Equals or BinaryOperatorKind.NotEquals)
            {
                var op = b.OperatorKind == BinaryOperatorKind.Equals ? " == " : " != ";
                if (lt != null && lt.TypeKind == TypeKind.Delegate && IsNullConst(b.RightOperand)) return "(" + X(b.LeftOperand) + ".f" + op + "null)";
                if (rtp != null && rtp.TypeKind == TypeKind.Delegate && IsNullConst(b.LeftOperand)) return "(" + X(b.RightOperand) + ".f" + op + "null)";
                if (lt != null && lt.SpecialType == SpecialType.System_String) return Todo("string comparison");
            }
            var l = X(b.LeftOperand);
            var r = X(b.RightOperand);
            return ArithOp(b.OperatorKind, l, r, lt ?? b.Type!);
        }

        static bool IsNullConst(IOperation o)
        {
            while (o is IConversionOperation c) o = c.Operand;
            return o.ConstantValue.HasValue && o.ConstantValue.Value == null;
        }

        /// <summary>An operator of a runtime type. Pointers (CPtr, Ptr, Iter) are Zig pointers, so their arithmetic
        /// and comparisons are written out; the other types' operators are runtime functions.</summary>
        string UserBinary(IMethodSymbol op, string l, string r, ITypeSymbol lt, ITypeSymbol rtp)
        {
            if (!IsRuntime(op)) return Todo("engine operator " + op.Name);
            var t = op.ContainingType;
            var tn = StripArity(t.Name);
            if (tn == "CPtr" || tn == "Ptr")
            {
                bool rIsPtr = IsPtrType(op.Parameters[1].Type);
                switch (op.Name)
                {
                    case "op_Addition": return "rt.padd(" + l + ", " + r + ")";
                    case "op_Subtraction": return rIsPtr ? "rt.pdiff(" + l + ", " + r + ")" : "rt.psub(" + l + ", " + r + ")";
                    case "op_Equality": return "(" + l + " == " + r + ")";
                    case "op_Inequality": return "(" + l + " != " + r + ")";
                    case "op_LessThan": return "rt.plt(" + l + ", " + r + ")";
                    case "op_GreaterThan": return "rt.plt(" + r + ", " + l + ")";
                    case "op_LessThanOrEqual": return "!rt.plt(" + r + ", " + l + ")";
                    case "op_GreaterThanOrEqual": return "!rt.plt(" + l + ", " + r + ")";
                }
                return Todo("pointer operator " + op.Name);
            }
            return RuntimeOpCall(op, new[] { l, r });
        }

        string RuntimeOpCall(IMethodSymbol op, string[] args)
        {
            var t = op.ContainingType;
            var tn = StripArity(t.Name);
            if ((tn == "CPtr" || tn == "Ptr") && args.Length == 1)
            {
                if (op.Name == "op_Increment") return "rt.padd(" + args[0] + ", 1)";
                if (op.Name == "op_Decrement") return "rt.padd(" + args[0] + ", -1)";
            }
            var opn = op.Name switch
            {
                "op_Addition" => "add", "op_Subtraction" => "sub", "op_Equality" => "eq", "op_Inequality" => "ne",
                "op_LessThan" => "lt", "op_GreaterThan" => "gt", "op_LessThanOrEqual" => "le", "op_GreaterThanOrEqual" => "ge",
                "op_Multiply" => "mul", "op_Division" => "div", "op_Increment" => "inc", "op_Decrement" => "dec",
                _ => Todo("operator " + op.Name)
            };
            var overloads = t.GetMembers(op.Name).OfType<IMethodSymbol>().Count();
            var sfx = overloads > 1 ? "_" + string.Join("_", op.OriginalDefinition.Parameters.Select(p => ShortType(p.Type))) : "";
            var n = "rt." + RuntimeTypeName(t) + ".op_" + opn + sfx;
            Use("operator " + op.OriginalDefinition.ToDisplayString(), "op_" + opn + sfx);
            return n + "(" + string.Join(", ", args) + ")";
        }

        string Unary(IUnaryOperation u)
        {
            if (u.OperatorMethod != null) return Todo("user unary operator");
            var o = X(u.Operand);
            var t = u.Operand.Type!;
            return u.OperatorKind switch
            {
                UnaryOperatorKind.Minus => IsFloat(t) ? "(-" + o + ")" : "(-%" + o + ")",
                UnaryOperatorKind.Plus => o,
                UnaryOperatorKind.Not => "!(" + o + ")",
                UnaryOperatorKind.BitwiseNegation => "(~" + o + ")",
                _ => Todo("unary " + u.OperatorKind)
            };
        }

        string Ternary(IConditionalOperation c)
        {
            var cond = X(c.Condition);
            if (c.IsRef) return "(if (" + cond + ") " + Addr(c.WhenTrue) + " else " + Addr(c.WhenFalse!) + ").*";
            var t = c.Type!;
            return "@as(" + ZigType(t) + ", if (" + cond + ") " + Value(c.WhenTrue, t) + " else " + Value(c.WhenFalse!, t) + ")";
        }

        string CondAccess(IConditionalAccessOperation ca)
        {
            var t = ca.Type!;
            var o = Fresh("ca");
            var recv = X(ca.Operation);
            var ot = ca.Operation.Type!;
            if (ot.TypeKind == TypeKind.Delegate) return Todo("conditional access on a delegate value");
            condAccess.Push("@as(" + ZigType(ot) + ", " + o + ")");
            var w = Value(ca.WhenNotNull, t);
            condAccess.Pop();
            return "@as(" + ZigType(t) + ", if (" + recv + ") |" + o + "| " + w + " else " + Zero(t) + ")";
        }

        string IsType(IOperation v, ITypeSymbol t)
        {
            var from = v.Type!;
            if (t is INamedTypeSymbol nt && IsEngine(nt) && from is INamedTypeSymbol fn && IsEngine(fn))
            {
                var u = Fresh("u");
                return "(if (" + X(v) + ") |" + u + "| __isA(" + u + TidPath(fn) + ", " + Tid(nt) + ") else false)";
            }
            return Todo("is " + t.ToDisplayString() + " on " + from.ToDisplayString());
        }

        // ---- lambdas: a Zig function with a context struct holding pointers to the captured variables' cells
        string Lambda(IAnonymousFunctionOperation af, ITypeSymbol? target)
        {
            var m = af.Symbol;
            var n = ++lambdaCount;
            var fname = "__lam" + n;
            var caps = CapturedBy(af, out var usesThis);
            usesThis = usesThis && !(method?.IsStatic ?? true) || (usesThis && inLambda && capturesThis);
            var sub = new Fn(this, m) { capturesThis = usesThis };
            var ctxType = "__Ctx" + n;
            var fields = new List<string>();
            var inits = new List<string>();
            if (usesThis)
            {
                fields.Add("this: ?*" + TypeIdent(cls));
                inits.Add(".this = " + ThisRef());
            }
            int k = 0;
            foreach (var s in caps)
            {
                var fn = "c" + (k++) + "_" + Id(s.Name);
                var st = s is ILocalSymbol ls ? ls.Type : ((IParameterSymbol)s).Type;
                fields.Add(fn + ": *" + ZigType(st));
                inits.Add("." + fn + " = " + AddrOf(s));
                sub.captured[s] = fn;
            }
            var ps = new List<string> { "__ctx: ?*anyopaque" };
            foreach (var p in m.Parameters) ps.Add(sub.ParamName(p) + ": " + ParamType(p));
            var body = sub.Body(af.Body, m.Parameters, false);
            var f = new StringBuilder();
            if (fields.Count > 0)
            {
                f.Append("const ").Append(ctxType).Append(" = struct { ").Append(string.Join(", ", fields)).Append(" };\n");
                f.Append("fn ").Append(fname).Append('(').Append(string.Join(", ", ps)).Append(") E!").Append(RetType(m)).Append(" {\n");
                f.Append("    const __c: *").Append(ctxType).Append(" = @ptrCast(@alignCast(__ctx.?));\n    _ = &__c;\n");
            }
            else
            {
                f.Append("fn ").Append(fname).Append('(').Append(string.Join(", ", ps)).Append(") E!").Append(RetType(m)).Append(" {\n");
                f.Append("    _ = &__ctx;\n");
            }
            f.Append(body).Append("}\n\n");
            funcs.Append(f);
            var dt = target != null && target.TypeKind == TypeKind.Delegate ? ZigType(target) : DelegateOf(m);
            var ctx = fields.Count == 0 ? "null" : "rt.ctxOf(" + ctxType + ", .{ " + string.Join(", ", inits) + " })";
            return "(" + dt + "{ .ctx = " + ctx + ", .f = &" + fname + " })";
        }

        static string DelegateOf(IMethodSymbol m)
        {
            var ps = m.Parameters.Select(ParamType).ToList();
            ps.Add(RetType(m));
            return "rt.Fn" + m.Parameters.Length + "(" + string.Join(", ", ps) + ")";
        }

        string DelegateCreation(IDelegateCreationOperation dc, ITypeSymbol? target = null)
        {
            var t = target ?? dc.Type!;
            if (dc.Target is IAnonymousFunctionOperation af) return Lambda(af, t);
            if (dc.Target is IMethodReferenceOperation mr)
            {
                var m = mr.Method;
                var inv = ((INamedTypeSymbol)t).DelegateInvokeMethod!;
                var n = ++thunkCount;
                var fname = "__thunk" + n;
                var ps = new List<string> { "__ctx: ?*anyopaque" };
                var args = new List<string>();
                int i = 0;
                foreach (var p in inv.Parameters) { ps.Add("a" + i + ": " + ParamType(p)); args.Add("a" + i); i++; }
                var f = new StringBuilder("fn " + fname + "(" + string.Join(", ", ps) + ") E!" + RetType(inv) + " {\n");
                string ctx;
                if (IsRuntime(m) || IsSystem(m)) return Todo("delegate of a runtime method " + m.Name);
                if (m.IsStatic) { f.Append("    _ = &__ctx;\n    return ").Append(FuncName(m)).Append('(').Append(string.Join(", ", args)).Append(");\n"); ctx = "null"; }
                else
                {
                    var ct = TypeIdent(m.ContainingType);
                    f.Append("    const o: ?*").Append(ct).Append(" = @ptrCast(@alignCast(__ctx));\n    return ").Append(FuncName(m)).Append("(o").Append(args.Count > 0 ? ", " + string.Join(", ", args) : "").Append(");\n");
                    var recvT = mr.Instance!.Type as INamedTypeSymbol;
                    var r = X(mr.Instance!);
                    if (recvT != null && !SymbolEqualityComparer.Default.Equals(recvT.OriginalDefinition, m.ContainingType.OriginalDefinition)) r = Upcast(r, recvT, m.ContainingType);
                    ctx = "@ptrCast(" + r + ")";
                }
                f.Append("}\n\n");
                funcs.Append(f);
                return "(" + ZigType(t) + "{ .ctx = " + ctx + ", .f = &" + fname + " })";
            }
            return Todo("delegate creation " + dc.Target.Kind);
        }
    }
}

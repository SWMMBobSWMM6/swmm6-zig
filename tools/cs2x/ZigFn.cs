// ZigFn.cs - method bodies: C# statements and expressions (Roslyn IOperation trees) to Zig.
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
    static int lambdaCount, thunkCount;

    public sealed partial class Fn
    {
        readonly IMethodSymbol? method;
        readonly INamedTypeSymbol cls;
        readonly string retZig;              // the Zig type a return statement returns (without the error union)
        readonly bool retRef;
        readonly Dictionary<ISymbol, string> names = new(SymbolEqualityComparer.Default);
        readonly HashSet<ISymbol> refVars = new(SymbolEqualityComparer.Default);   // hold a pointer: x.*
        readonly HashSet<ISymbol> cells = new(SymbolEqualityComparer.Default);     // captured by a lambda: a heap cell, x.*
        readonly Dictionary<ISymbol, string> captured = new(SymbolEqualityComparer.Default);   // in a lambda: __c.f.*
        readonly HashSet<string> used = new();
        int tmp;
        readonly bool inLambda;
        bool capturesThis;
        // throw targets: the try regions a throw or a failed call leaves to (innermost last)
        readonly List<Target> targets = new();
        // break targets: "loop", or the label of a switch
        readonly List<string> breakables = new();
        bool hoist;
        readonly List<string> hoisted = new();
        readonly Dictionary<string, int> gotoLabels = new();
        string? rethrowVar;

        sealed class Target { public string Label = ""; public string St = ""; public bool Fin; public string? Rv; public bool Handler; }

        public Fn(IMethodSymbol? m, INamedTypeSymbol c, string ret)
        {
            method = m; cls = c; retZig = ret; retRef = m != null && m.RefKind != RefKind.None;
            foreach (var r in ZigReserved) used.Add(r);
        }

        Fn(Fn parent, IMethodSymbol lambda)
        {
            inLambda = true;
            method = lambda; cls = parent.cls; retZig = RetType(lambda); retRef = lambda.RefKind != RefKind.None;
            foreach (var r in ZigReserved) used.Add(r);
        }

        string Fresh(string b) { tmp++; return "__" + b + tmp; }

        string Declare(ISymbol s, string name)
        {
            var n = Id(name);
            if (n == "_") n = "__discard";
            if (n.StartsWith("__")) n = "v" + n;
            var b = n; int k = 2;
            while (used.Contains(n)) n = b + "_" + k++;
            used.Add(n);
            names[s] = n;
            return n;
        }

        public string ParamName(IParameterSymbol p) => "p_" + Id(p.Name);

        static string Ind(int n) => new string(' ', 4 * n);

        // -------------------------------------------------------------------------------------------- captures
        /// <summary>The locals and parameters a lambda (or one nested in it) uses that are declared outside it.</summary>
        static List<ISymbol> CapturedBy(IAnonymousFunctionOperation lam, out bool usesThis)
        {
            var res = new List<ISymbol>();
            var seen = new HashSet<ISymbol>(SymbolEqualityComparer.Default);
            usesThis = false;
            foreach (var d in lam.Body.DescendantsAndSelf())
            {
                ISymbol? s = d switch { ILocalReferenceOperation l => l.Local, IParameterReferenceOperation p => p.Parameter, _ => null };
                if (d is IInstanceReferenceOperation ir && ir.ReferenceKind == InstanceReferenceKind.ContainingTypeInstance) usesThis = true;
                if (s == null || Within(s, lam.Symbol)) continue;
                if (seen.Add(s)) res.Add(s);
            }
            return res;
        }

        static bool Within(ISymbol s, IMethodSymbol lam)
        {
            for (var c = s.ContainingSymbol; c != null; c = c.ContainingSymbol)
                if (SymbolEqualityComparer.Default.Equals(c, lam)) return true;
            return false;
        }

        void FindCells(IOperation body)
        {
            foreach (var lam in body.Descendants().OfType<IAnonymousFunctionOperation>())
                foreach (var s in CapturedBy(lam, out _))
                    if (SymbolEqualityComparer.Default.Equals(s.ContainingSymbol, method)) cells.Add(s);
        }

        // -------------------------------------------------------------------------------------------- bodies
        /// <summary>The Zig statements of a method, lambda or constructor body (the parameters first copied into
        /// variables, since C# may assign them).</summary>
        public string Body(IOperation op, IEnumerable<IParameterSymbol> ps, bool hasThis, bool isCtor = false)
        {
            var lines = new List<string>();
            if (hasThis && !inLambda) { used.Add("this"); lines.Add(Ind(1) + "_ = &this;"); }
            FindCells(op);
            foreach (var p in ps)
            {
                var n = Declare(p, p.Name);
                if (p.RefKind != RefKind.None) { refVars.Add(p); lines.Add(Ind(1) + "var " + n + " = " + ParamName(p) + ";"); lines.Add(Ind(1) + "_ = &" + n + ";"); }
                else if (cells.Contains(p)) lines.Add(Ind(1) + "const " + n + " = rt.cell(" + ZigType(p.Type) + ", " + ParamName(p) + ");");
                else { lines.Add(Ind(1) + "var " + n + " = " + ParamName(p) + ";"); lines.Add(Ind(1) + "_ = &" + n + ";"); }
            }
            var ops = op is IBlockOperation b ? b.Operations.ToList() : op is IMethodBodyOperation mb && mb.BlockBody != null ? mb.BlockBody.Operations.ToList() : new List<IOperation> { op };
            hoist = op.Descendants().Any(d => d is IBranchOperation br && br.BranchKind == BranchKind.GoTo);
            var body = new List<string>();
            if (hoist) GotoBody(ops, body);
            else
            {
                // an expression body: a value to return
                if (op is not IBlockOperation && op is not IMethodBodyOperation && retZig != "void" && !isCtor && op is not IReturnOperation)
                {
                    var v = retRef ? Addr(op) : Value(op, method!.ReturnType);
                    body.Add(Ind(1) + "return " + v + ";");
                }
                else Block(ops, body, 1);
            }
            foreach (var h in hoisted) lines.Add(Ind(1) + h);
            lines.AddRange(body);
            if (retZig != "void" && !isCtor && !EndsInJump(lines)) lines.Add(Ind(1) + "unreachable;");
            return string.Concat(lines.Select(l => l + "\n"));
        }

        static bool EndsInJump(List<string> lines)
        {
            if (lines.Count == 0) return false;
            var s = lines[^1].Trim();
            // the keyword itself, not a name that begins with it (a local `breakdown = ...` once ended a loop body)
            return s.StartsWith("return ") || s == "return;" || s == "break;" || s.StartsWith("break :") || s == "continue;" ||
                s.StartsWith("continue :") || s == "unreachable;";
        }

        void Block(IEnumerable<IOperation> ops, List<string> lines, int ind)
        {
            var list = ops.ToList();
            for (int i = 0; i < list.Count; i++)
            {
                if (list[i] is IUsingDeclarationOperation ud)
                {
                    UsingRest(ud, list.Skip(i + 1).ToList(), lines, ind);
                    return;
                }
                Stmt(list[i], lines, ind);
                if (EndsInJump(lines) && LastAtLevel(lines, ind)) return;     // Zig rejects code after a jump
            }
        }

        static bool LastAtLevel(List<string> lines, int ind) => lines.Count > 0 && lines[^1].StartsWith(Ind(ind)) && !lines[^1].StartsWith(Ind(ind + 1));

        void Stmt(IOperation op, List<string> lines, int ind)
        {
            try { StmtInner(op, lines, ind); }
            catch (Todo e)
            {
                lines.Add(Ind(ind) + "@panic(\"TODO " + e.Message.Replace("\\", "\\\\").Replace("\"", "'") + "\");");
            }
        }

        void Sub(IOperation op, List<string> lines, int ind)
        {
            if (op is IBlockOperation b) Block(b.Operations, lines, ind);
            else Stmt(op, lines, ind);
        }

        void StmtInner(IOperation op, List<string> lines, int ind)
        {
            var p = Ind(ind);
            switch (op)
            {
                case IBlockOperation b:
                    lines.Add(p + "{");
                    Block(b.Operations, lines, ind + 1);
                    lines.Add(p + "}");
                    return;
                case IVariableDeclarationGroupOperation g:
                    foreach (var d in g.Declarations)
                        foreach (var v in d.Declarators) LocalDecl(v, d.Initializer, lines, ind);
                    return;
                case IExpressionStatementOperation es:
                    StmtExpr(es.Operation, lines, ind);
                    return;
                case IReturnOperation r: Return(r, lines, ind); return;
                case IConditionalOperation c: If(c, lines, ind); return;
                case IWhileLoopOperation w: While(w, lines, ind); return;
                case IForLoopOperation f: For(f, lines, ind); return;
                case IForEachLoopOperation fe: ForEach(fe, lines, ind); return;
                case IBranchOperation br: Branch(br, lines, ind); return;
                case ILabeledOperation l:
                    if (l.Operation != null) Stmt(l.Operation, lines, ind);
                    return;
                case ISwitchOperation sw: Switch(sw, lines, ind); return;
                case ITryOperation t: Try(t, lines, ind); return;
                case IThrowOperation th:
                    {
                        if (th.Exception == null)
                        {
                            if (rethrowVar == null) Todo("throw; outside a catch");
                            lines.Add(p + "rt.setExc(" + rethrowVar + ");");
                        }
                        else lines.Add(p + "rt.setExc(" + ExcValue(th.Exception) + ");");
                        lines.Add(p + ThrowJump());
                        return;
                    }
                case IEmptyOperation: return;
                case IUsingDeclarationOperation ud: UsingRest(ud, new List<IOperation>(), lines, ind); return;
                case ILocalFunctionOperation: Todo("local function"); return;
                default: Todo("statement " + op.Kind); return;
            }
        }

        /// <summary>A thrown object as the runtime's exception pointer.</summary>
        string ExcValue(IOperation e)
        {
            while (e is IConversionOperation cv && cv.IsImplicit) e = cv.Operand;
            var t = e.Type as INamedTypeSymbol;
            var v = X(e);
            if (t != null && IsEngine(t)) return ToRuntimeBase(v, t);
            return v;
        }

        /// <summary>An engine object (whose hierarchy rests on rt.CppException) as its runtime base.</summary>
        string ToRuntimeBase(string v, INamedTypeSymbol t)
        {
            var path = ""; var c = t;
            while (c.BaseType != null && IsEngine(c.BaseType)) { path += ".__base"; c = c.BaseType; }
            if (c.BaseType == null || !IsRuntime(c.BaseType)) Todo("throw of a non-exception " + t.Name);
            var u = Fresh("u");
            return "(if (" + v + ") |" + u + "| &" + u + path + ".__base else null)";
        }

        /// <summary>Leave for the innermost try region with the exception pending, or return the error.</summary>
        string ThrowJump()
        {
            if (targets.Count == 0) return "return error.Throw;";
            var t = targets[^1];
            return "{ " + t.St + " = 1; break :" + t.Label + "; }";
        }

        /// <summary>A call that can throw: `try` it, or inside a try region branch to the region on failure.</summary>
        string Call(string e)
        {
            if (targets.Count == 0) return "(try " + e + ")";
            var t = targets[^1];
            return "(" + e + " catch { " + t.St + " = 1; break :" + t.Label + "; })";
        }

        void LocalDecl(IVariableDeclaratorOperation v, IVariableInitializerOperation? outerInit, List<string> lines, int ind)
        {
            var p = Ind(ind);
            var loc = v.Symbol;
            var init = v.Initializer ?? outerInit;
            if (loc.RefKind != RefKind.None)
            {
                var a = init == null ? "undefined" : Addr(init.Value);
                var n = Declare(loc, loc.Name);
                refVars.Add(loc);
                var pt = "*" + ZigType(loc.Type);
                if (hoist) { hoisted.Add("var " + n + ": " + pt + " = undefined;"); hoisted.Add("_ = &" + n + ";"); lines.Add(p + n + " = " + a + ";"); return; }
                lines.Add(p + "var " + n + ": " + pt + " = " + a + ";");
                lines.Add(p + "_ = &" + n + ";");
                return;
            }
            var zt = ZigType(loc.Type);
            string val = init == null ? Zero(loc.Type) : Value(init.Value, loc.Type);
            var name = Declare(loc, loc.Name);
            if (cells.Contains(loc))
            {
                if (hoist) Todo("captured local in a function with goto");
                lines.Add(p + "const " + name + " = rt.cell(" + zt + ", " + val + ");");
                return;
            }
            if (hoist)
            {
                hoisted.Add("var " + name + ": " + zt + " = " + Zero(loc.Type) + ";");
                hoisted.Add("_ = &" + name + ";");
                if (init != null) lines.Add(p + name + " = " + val + ";");
                return;
            }
            lines.Add(p + "var " + name + ": " + zt + " = " + val + ";");
            lines.Add(p + "_ = &" + name + ";");
        }

        /// <summary>A static field's initializer, as statements assigning name.</summary>
        public void AssignInto(string name, IOperation value, ITypeSymbol t, List<string> lines, int ind)
        {
            lines.Add(Ind(ind) + name + " = " + Value(value, t) + ";");
        }

        void Return(IReturnOperation r, List<string> lines, int ind)
        {
            var p = Ind(ind);
            string? v = null;
            if (r.ReturnedValue != null) v = retRef ? Addr(r.ReturnedValue) : Value(r.ReturnedValue, method?.ReturnType);
            // a finally between here and the function: run it first (the region's state 2 carries the value)
            var fin = targets.LastOrDefault(t => t.Fin);
            if (fin != null)
            {
                if (targets.Count(t => t.Fin) > 1) Todo("return through two finally blocks");
                lines.Add(p + "{");
                if (v != null) lines.Add(Ind(ind + 1) + fin.Rv + " = " + v + ";");
                lines.Add(Ind(ind + 1) + fin.St + " = 2;");
                lines.Add(Ind(ind + 1) + "break :" + fin.Label + ";");
                lines.Add(p + "}");
                return;
            }
            lines.Add(p + "return" + (v != null ? " " + v : "") + ";");
        }

        void If(IConditionalOperation c, List<string> lines, int ind)
        {
            var p = Ind(ind);
            lines.Add(p + "if (" + X(c.Condition) + ") {");
            Sub(c.WhenTrue, lines, ind + 1);
            if (c.WhenFalse == null) { lines.Add(p + "}"); return; }
            lines.Add(p + "} else {");
            Sub(c.WhenFalse, lines, ind + 1);
            lines.Add(p + "}");
        }

        void LoopBody(IOperation body, List<string> lines, int ind)
        {
            breakables.Add("loop");
            Sub(body, lines, ind);
            breakables.RemoveAt(breakables.Count - 1);
        }

        void While(IWhileLoopOperation w, List<string> lines, int ind)
        {
            var p = Ind(ind);
            if (w.ConditionIsTop)
            {
                var cond = w.Condition == null ? "true" : X(w.Condition);
                lines.Add(p + "while (" + cond + ") {");
                LoopBody(w.Body, lines, ind + 1);
                lines.Add(p + "}");
                return;
            }
            // do { body } while (cond): a continue must still test the condition
            var first = Fresh("first");
            lines.Add(p + "{");
            lines.Add(Ind(ind + 1) + "var " + first + " = true;");
            lines.Add(Ind(ind + 1) + "while (" + first + " or " + X(w.Condition!) + ") : (" + first + " = false) {");
            LoopBody(w.Body, lines, ind + 2);
            lines.Add(Ind(ind + 1) + "}");
            lines.Add(p + "}");
        }

        void For(IForLoopOperation f, List<string> lines, int ind)
        {
            var p = Ind(ind);
            lines.Add(p + "{");
            foreach (var b in f.Before) Stmt(b, lines, ind + 1);
            var cond = f.Condition == null ? "true" : X(f.Condition);
            var posts = new List<string>();
            foreach (var a in f.AtLoopBottom)
            {
                var pl = new List<string>();
                if (a is IExpressionStatementOperation es) StmtExpr(es.Operation, pl, 0);
                else Stmt(a, pl, 0);
                posts.AddRange(pl.Select(x => x.Trim()));
            }
            string post = posts.Count == 0 ? "" : " : ({ " + string.Join(" ", posts) + " })";
            if (posts.Count == 1 && posts[0].EndsWith(";") && !posts[0].Contains("\n") && !posts[0].StartsWith("{") && !posts[0].StartsWith("_ ="))
                post = " : (" + posts[0].TrimEnd(';') + ")";
            lines.Add(Ind(ind + 1) + "while (" + cond + ")" + post + " {");
            LoopBody(f.Body, lines, ind + 2);
            lines.Add(Ind(ind + 1) + "}");
            lines.Add(p + "}");
        }

        void ForEach(IForEachLoopOperation fe, List<string> lines, int ind)
        {
            var p = Ind(ind);
            var coll = fe.Collection is IConversionOperation cv && cv.IsImplicit ? cv.Operand : fe.Collection;
            var ct = coll.Type!;
            if (fe.LoopControlVariable is not IVariableDeclaratorOperation vd) { Todo("foreach variable"); return; }
            var loc = vd.Symbol;
            var zt = ZigType(loc.Type);
            lines.Add(p + "{");
            if (ct is IArrayTypeSymbol)
            {
                var a = Fresh("arr"); var i = Fresh("i");
                lines.Add(Ind(ind + 1) + "const " + a + " = " + X(coll) + ";");
                lines.Add(Ind(ind + 1) + "var " + i + ": usize = 0;");
                lines.Add(Ind(ind + 1) + "while (" + i + " < " + a + ".?.len) : (" + i + " += 1) {");
                var name = Declare(loc, loc.Name);
                if (cells.Contains(loc)) lines.Add(Ind(ind + 2) + "const " + name + " = rt.cell(" + zt + ", " + a + ".?[" + i + "]);");
                else { lines.Add(Ind(ind + 2) + "var " + name + ": " + zt + " = " + a + ".?[" + i + "];"); lines.Add(Ind(ind + 2) + "_ = &" + name + ";"); }
            }
            else
            {
                // a runtime enumeration (Items()): an iterator with next()
                var it = Fresh("it"); var x = Fresh("x");
                lines.Add(Ind(ind + 1) + "var " + it + " = " + X(coll) + ";");
                lines.Add(Ind(ind + 1) + "while (" + it + ".next()) |" + x + "| {");
                var name = Declare(loc, loc.Name);
                if (cells.Contains(loc)) lines.Add(Ind(ind + 2) + "const " + name + " = rt.cell(" + zt + ", " + x + ");");
                else { lines.Add(Ind(ind + 2) + "var " + name + ": " + zt + " = " + x + ";"); lines.Add(Ind(ind + 2) + "_ = &" + name + ";"); }
            }
            LoopBody(fe.Body, lines, ind + 2);
            lines.Add(Ind(ind + 1) + "}");
            lines.Add(p + "}");
        }

        void Branch(IBranchOperation br, List<string> lines, int ind)
        {
            var p = Ind(ind);
            switch (br.BranchKind)
            {
                case BranchKind.Break:
                    if (breakables.Count > 0 && breakables[^1] != "loop") { lines.Add(p + "break :" + breakables[^1] + ";"); return; }
                    CheckFinallyJump();
                    lines.Add(p + "break;");
                    return;
                case BranchKind.Continue:
                    CheckFinallyJump();
                    lines.Add(p + "continue;");
                    return;
                case BranchKind.GoTo:
                    if (!gotoLabels.TryGetValue(br.Target.Name, out var k)) { Todo("goto into a nested statement"); return; }
                    lines.Add(p + "{");
                    lines.Add(Ind(ind + 1) + "__pc = " + k + ";");
                    lines.Add(Ind(ind + 1) + "continue :__disp;");
                    lines.Add(p + "}");
                    return;
            }
            Todo("branch " + br.BranchKind);
        }

        void CheckFinallyJump()
        {
            // a break or continue that leaves a region with a finally would skip it
            int loopAt = breakables.FindLastIndex(b => b == "loop");
            if (targets.Any(t => t.Fin) && loopAt < 0) Todo("break or continue out of a finally region");
        }

        /// <summary>A function with goto: its top-level statements cut at each label into the cases of a dispatch loop
        /// (Zig has no goto). Every local is declared at the top.</summary>
        void GotoBody(List<IOperation> ops, List<string> lines)
        {
            var segs = new List<List<IOperation>> { new() };
            foreach (var o in ops)
            {
                if (o is ILabeledOperation l)
                {
                    gotoLabels[l.Label.Name] = segs.Count;
                    segs.Add(new List<IOperation> { o });
                }
                else segs[^1].Add(o);
            }
            foreach (var d in ops.SelectMany(o => o.DescendantsAndSelf()).OfType<ILabeledOperation>())
                if (!gotoLabels.ContainsKey(d.Label.Name)) Todo("label inside a nested statement");
            hoisted.Add("var __pc: u32 = 0;");
            hoisted.Add("_ = &__pc;");
            lines.Add(Ind(1) + "__disp: while (true) {");
            lines.Add(Ind(2) + "switch (__pc) {");
            for (int i = 0; i < segs.Count; i++)
            {
                lines.Add(Ind(3) + i + " => {");
                var seg = new List<string>();
                Block(segs[i], seg, 4);
                lines.AddRange(seg);
                if (!(EndsInJump(seg) && LastAtLevel(seg, 4)))
                {
                    if (i + 1 < segs.Count) { lines.Add(Ind(4) + "__pc = " + (i + 1) + ";"); lines.Add(Ind(4) + "continue :__disp;"); }
                    else lines.Add(Ind(4) + "break :__disp;");
                }
                lines.Add(Ind(3) + "},");
            }
            lines.Add(Ind(3) + "else => unreachable,");
            lines.Add(Ind(2) + "}");
            lines.Add(Ind(1) + "}");
        }

        void Switch(ISwitchOperation sw, List<string> lines, int ind)
        {
            var p = Ind(ind);
            var lbl = Fresh("sw");
            var vt = sw.Value.Type!;
            bool integral = IsIntegral(vt) || vt.TypeKind == TypeKind.Enum;
            int labelAt = lines.Count;
            lines.Add(p + lbl + ": {");
            breakables.Add(lbl);
            if (integral)
            {
                var v = Fresh("sv");
                lines.Add(Ind(ind + 1) + "const " + v + " = " + X(sw.Value) + ";");
                lines.Add(Ind(ind + 1) + "switch (" + v + ") {");
                bool hasDefault = false;
                foreach (var c in sw.Cases)
                {
                    var labels = new List<string>();
                    bool def = false;
                    foreach (var cl in c.Clauses)
                    {
                        if (cl is IDefaultCaseClauseOperation) def = true;
                        else if (cl is ISingleValueCaseClauseOperation sv && sv.Value.ConstantValue.HasValue) labels.Add(IntLit(sv.Value.ConstantValue.Value!));
                        else Todo("case clause " + cl.CaseKind);
                    }
                    if (def) hasDefault = true;
                    lines.Add(Ind(ind + 2) + (def ? "else" : string.Join(", ", labels)) + " => {");
                    var body = c.Body.ToList();
                    if (body.Count > 0 && body[^1] is IBranchOperation lb && lb.BranchKind == BranchKind.Break) body.RemoveAt(body.Count - 1);
                    Block(body, lines, ind + 3);
                    lines.Add(Ind(ind + 2) + "},");
                }
                if (!hasDefault) lines.Add(Ind(ind + 2) + "else => {},");
                lines.Add(Ind(ind + 1) + "}");
            }
            else
            {
                // a switch on another type (a string): a chain of comparisons
                var v = Fresh("sv");
                lines.Add(Ind(ind + 1) + "const " + v + " = " + X(sw.Value) + ";");
                lines.Add(Ind(ind + 1) + "_ = &" + v + ";");
                ISwitchCaseOperation? defCase = null;
                bool first = true;
                foreach (var c in sw.Cases)
                {
                    if (c.Clauses.Any(cl => cl is IDefaultCaseClauseOperation)) { defCase = c; continue; }
                    var tests = c.Clauses.Select(cl => cl is ISingleValueCaseClauseOperation sv ? EqTest(v, vt, sv.Value) : Todo("case clause " + cl.CaseKind)).ToList();
                    lines.Add(Ind(ind + 1) + (first ? "if (" : "} else if (") + string.Join(" or ", tests) + ") {");
                    first = false;
                    var body = c.Body.ToList();
                    if (body.Count > 0 && body[^1] is IBranchOperation lb && lb.BranchKind == BranchKind.Break) body.RemoveAt(body.Count - 1);
                    Block(body, lines, ind + 2);
                }
                if (defCase != null)
                {
                    lines.Add(Ind(ind + 1) + (first ? "{" : "} else {"));
                    var body = defCase.Body.ToList();
                    if (body.Count > 0 && body[^1] is IBranchOperation lb && lb.BranchKind == BranchKind.Break) body.RemoveAt(body.Count - 1);
                    Block(body, lines, ind + 2);
                    lines.Add(Ind(ind + 1) + "}");
                }
                else if (!first) lines.Add(Ind(ind + 1) + "}");
            }
            breakables.RemoveAt(breakables.Count - 1);
            lines.Add(p + "}");
            DropUnusedLabel(lines, labelAt, lbl);
        }

        /// <summary>Zig rejects a label nothing breaks to: keep the block, drop the label.</summary>
        static void DropUnusedLabel(List<string> lines, int at, string lbl)
        {
            for (int i = at + 1; i < lines.Count; i++)
                if (lines[i].Contains(":" + lbl + ";") || lines[i].Contains(":" + lbl + " ")) return;
            lines[at] = lines[at].Replace(lbl + ": {", "{");
        }

        string EqTest(string v, ITypeSymbol vt, IOperation c)
        {
            if (vt.SpecialType == SpecialType.System_String) return "rt.strEq(" + v + ", " + X(c) + ")";
            return Todo("switch on " + vt.ToDisplayString());
        }

        // -------------------------------------------------------------------------------------------- try regions
        // try { A } catch (T e) { B } finally { C }:
        //   { var st: u8 = 0; tryN: { A } if (st == 1) { if (isA(T)) { st = 0; B } } C; if (st == 1) throw; if (st == 2) return rv; }
        // where every call in A that fails, and every throw, sets st = 1 and leaves tryN.
        void Try(ITryOperation t, List<string> lines, int ind)
        {
            Region(lines, ind, (ls, i) => Block(t.Body.Operations, ls, i), t.Catches, t.Finally == null ? null : (ls, i) => Block(t.Finally.Operations, ls, i));
        }

        void Region(List<string> lines, int ind, Action<List<string>, int> body, IEnumerable<ICatchClauseOperation> catches, Action<List<string>, int>? fin)
        {
            var p = Ind(ind);
            var n = Fresh("t");
            var st = "__st" + n; var lbl = "__try" + n;
            var tg = new Target { Label = lbl, St = st, Fin = fin != null };
            lines.Add(p + "{");
            lines.Add(Ind(ind + 1) + "var " + st + ": u8 = 0;");
            lines.Add(Ind(ind + 1) + "_ = &" + st + ";");
            if (fin != null && retZig != "void")
            {
                tg.Rv = "__rv" + n;
                lines.Add(Ind(ind + 1) + "var " + tg.Rv + ": " + retZig + " = undefined;");
                lines.Add(Ind(ind + 1) + "_ = &" + tg.Rv + ";");
            }
            // breakables inside the region keep their meaning (a break leaves a loop or a switch outside)
            targets.Add(tg);
            int labelAt = lines.Count;
            lines.Add(Ind(ind + 1) + lbl + ": {");
            body(lines, ind + 2);
            lines.Add(Ind(ind + 1) + "}");
            targets.RemoveAt(targets.Count - 1);
            DropUnusedLabel(lines, labelAt, lbl);
            var cl = catches.ToList();
            if (cl.Count > 0)
            {
                var ev = "__e" + n;
                lines.Add(Ind(ind + 1) + "if (" + st + " == 1) {");
                lines.Add(Ind(ind + 2) + "const " + ev + " = rt.excGet();");
                lines.Add(Ind(ind + 2) + "_ = &" + ev + ";");
                bool first = true;
                foreach (var cc in cl)
                {
                    var et = cc.ExceptionType;
                    string test;
                    if (et.SpecialType == SpecialType.System_Object || (et is INamedTypeSymbol en && IsSystem(en) && en.Name == "Exception")) test = "true";
                    else if (et is INamedTypeSymbol nt) test = "__isA(" + ev + ".?.tid, " + TargetTid(nt) + ")";
                    else { Todo("catch type"); return; }
                    if (cc.Filter != null) Todo("catch filter");
                    lines.Add(Ind(ind + 2) + (first ? "if (" : "} else if (") + test + ") {");
                    first = false;
                    lines.Add(Ind(ind + 3) + st + " = 0;");
                    if (cc.ExceptionDeclarationOrExpression is IVariableDeclaratorOperation vd)
                    {
                        var name = Declare(vd.Symbol, vd.Symbol.Name);
                        string val = ev;
                        if (et is INamedTypeSymbol ent && IsEngine(ent)) val = FromRuntimeBase(ev, ent);
                        lines.Add(Ind(ind + 3) + "var " + name + ": " + ZigType(vd.Symbol.Type) + " = " + val + ";");
                        lines.Add(Ind(ind + 3) + "_ = &" + name + ";");
                    }
                    var saved = rethrowVar; rethrowVar = ev;
                    if (fin != null)
                    {
                        // a throw from the handler still runs the finally: the handler is a region of its own
                        var hl = "__h" + n;
                        targets.Add(new Target { Label = hl, St = st, Fin = true, Rv = tg.Rv, Handler = true });
                        int hAt = lines.Count;
                        lines.Add(Ind(ind + 3) + hl + ": {");
                        Block(cc.Handler.Operations, lines, ind + 4);
                        lines.Add(Ind(ind + 3) + "}");
                        targets.RemoveAt(targets.Count - 1);
                        DropUnusedLabel(lines, hAt, hl);
                    }
                    else Block(cc.Handler.Operations, lines, ind + 3);
                    rethrowVar = saved;
                }
                lines.Add(Ind(ind + 2) + "}");
                lines.Add(Ind(ind + 1) + "}");
            }
            if (fin != null) fin(lines, ind + 1);
            lines.Add(Ind(ind + 1) + "if (" + st + " == 1) " + ThrowJump());
            if (fin != null)
            {
                var outerFin = targets.LastOrDefault(x => x.Fin);
                if (outerFin != null) Todo("nested finally regions");
                lines.Add(Ind(ind + 1) + "if (" + st + " == 2) return" + (tg.Rv != null ? " " + tg.Rv : "") + ";");
            }
            lines.Add(p + "}");
        }

        /// <summary>The engine object behind a caught runtime exception pointer.</summary>
        string FromRuntimeBase(string ev, INamedTypeSymbol t)
        {
            var chain = new List<INamedTypeSymbol>();
            for (var c = t.OriginalDefinition; ; c = c.BaseType!.OriginalDefinition)
            {
                chain.Add(c);
                if (c.BaseType == null || !IsEngine(c.BaseType)) break;
            }
            var e = ev + ".?";
            for (int i = chain.Count - 1; i >= 0; i--) e = "@as(*" + TypeIdent(chain[i]) + ", @alignCast(@fieldParentPtr(\"__base\", " + e + ")))";
            return e;
        }

        void UsingRest(IUsingDeclarationOperation ud, List<IOperation> rest, List<string> lines, int ind)
        {
            var decls = ud.DeclarationGroup.Declarations.SelectMany(d => d.Declarators).ToList();
            lines.Add(Ind(ind) + "{");
            foreach (var d in ud.DeclarationGroup.Declarations)
                foreach (var v in d.Declarators) LocalDecl(v, d.Initializer, lines, ind + 1);
            Region(lines, ind + 1, (ls, i) => Block(rest, ls, i), Array.Empty<ICatchClauseOperation>(), (ls, i) =>
            {
                foreach (var v in decls.AsEnumerable().Reverse())
                    ls.Add(Ind(i) + Call(DisposeCall(VarRef(v.Symbol), v.Symbol.Type)) + ";");
            });
            lines.Add(Ind(ind) + "}");
        }

        /// <summary>Dispose (a using declaration's end): the runtime's for its types, the engine class's own.</summary>
        string DisposeCall(string v, ITypeSymbol t)
        {
            if (t is INamedTypeSymbol nt && IsEngine(nt)) return TypeIdent(nt) + ".__dispose(" + v + ")";
            return "rt.dispose(" + v + ")";
        }

        // -------------------------------------------------------------------------------------------- expression statements
        void StmtExpr(IOperation op, List<string> lines, int ind)
        {
            var p = Ind(ind);
            switch (op)
            {
                case ISimpleAssignmentOperation a:
                    {
                        if (a.Target is IDiscardOperation)
                        {
                            var inner = a.Value;
                            while (inner is IConversionOperation cv && cv.IsImplicit) inner = cv.Operand;
                            if (inner is ISimpleAssignmentOperation or ICompoundAssignmentOperation or IIncrementOrDecrementOperation or IInvocationOperation) { StmtExpr(inner, lines, ind); return; }
                            lines.Add(p + "_ = " + X(a.Value) + ";");
                            return;
                        }
                        if (a.IsRef) { lines.Add(p + RefRebind(a.Target) + " = " + Addr(a.Value) + ";"); return; }
                        if (IsCPtrElem(a.Target, out var pe, out var pi)) { lines.Add(p + "rt.cset(" + pe + ", " + pi + ", " + Value(a.Value, a.Target.Type) + ");"); return; }
                        var v = Value(a.Value, a.Target.Type);
                        lines.Add(p + Place(a.Target) + " = " + v + ";");
                        return;
                    }
                case ICompoundAssignmentOperation ca:
                    { var cs = CompoundStmt(ca); lines.Add(p + cs + (cs.StartsWith("{") ? "" : ";")); }
                    return;
                case IIncrementOrDecrementOperation inc:
                    { var cs = IncStmt(inc); lines.Add(p + cs + (cs.StartsWith("{") ? "" : ";")); }
                    return;
                case IInvocationOperation iv:
                    {
                        var s = X(op);
                        if (s == "{}") return;
                        bool hasValue = !iv.TargetMethod.ReturnsVoid;
                        lines.Add(p + (hasValue ? "_ = " : "") + s + ";");
                        return;
                    }
                case IObjectCreationOperation:
                    lines.Add(p + "_ = " + X(op) + ";");
                    return;
                case IConditionalAccessOperation ca when ca.Type == null || ca.Type.SpecialType == SpecialType.System_Void || ca.WhenNotNull is IInvocationOperation:
                    {
                        var o = Fresh("ca");
                        var recv = X(ca.Operation);
                        var ot = ca.Operation.Type!;
                        if (ot.TypeKind == TypeKind.Delegate)
                        {
                            lines.Add(p + "{");
                            lines.Add(Ind(ind + 1) + "const " + o + " = " + recv + ";");
                            lines.Add(Ind(ind + 1) + "if (" + o + ".f != null) {");
                            condAccess.Push(o);
                            StmtExpr(ca.WhenNotNull, lines, ind + 2);
                            condAccess.Pop();
                            lines.Add(Ind(ind + 1) + "}");
                            lines.Add(p + "}");
                            return;
                        }
                        lines.Add(p + "if (" + recv + ") |" + o + "| {");
                        condAccess.Push("@as(" + ZigType(ot) + ", " + o + ")");
                        StmtExpr(ca.WhenNotNull, lines, ind + 1);
                        condAccess.Pop();
                        lines.Add(p + "}");
                        return;
                    }
                case IDiscardOperation: return;
                default:
                    lines.Add(p + "_ = " + X(op) + ";");
                    return;
            }
        }

        string RefRebind(IOperation target)
        {
            if (target is ILocalReferenceOperation l && refVars.Contains(l.Local)) return names[l.Local];
            if (target is IParameterReferenceOperation pr && refVars.Contains(pr.Parameter)) return names[pr.Parameter];
            return Todo("ref reassignment of " + target.Kind);
        }

        string CompoundStmt(ICompoundAssignmentOperation ca)
        {
            if (ca.OperatorMethod != null)
            {
                var pl = Place(ca.Target);
                return pl + " = " + UserBinary(ca.OperatorMethod, pl, X(ca.Value), ca.Target.Type!, ca.Value.Type!);
            }
            var tt = ca.Target.Type!;
            if (IsCPtrElem(ca.Target, out var pe, out var pi))
            {
                var t = Fresh("cp"); var k = Fresh("ck");
                return "{ const " + t + " = " + pe + "; const " + k + " = " + pi + "; rt.cset(" + t + ", " + k + ", " + ArithOp(ca.OperatorKind, "rt.cget(" + t + ", " + k + ")", Value(ca.Value, comp.GetSpecialType(SpecialType.System_Int32)), comp.GetSpecialType(SpecialType.System_Int32)) + "); }";
            }
            var opT = ca.Value.Type!;
            bool conv = ca.InConversion.Exists && !ca.InConversion.IsIdentity || ca.OutConversion.Exists && !ca.OutConversion.IsIdentity;
            var place = Place(ca.Target);
            // evaluate the place once when it has calls or side effects
            if (!SimplePlace(place))
            {
                var ptr = Fresh("cp");
                var addr = Addr(ca.Target);
                var cur = ptr + ".*";
                var nv = conv ? Conv(ArithOp(ca.OperatorKind, Conv(cur, tt, opT), X(ca.Value), opT), opT, tt) : ArithOp(ca.OperatorKind, cur, X(ca.Value), tt);
                return "{ const " + ptr + " = " + addr + "; " + cur + " = " + nv + "; }";
            }
            if (conv) return place + " = " + Conv(ArithOp(ca.OperatorKind, Conv(place, tt, opT), X(ca.Value), opT), opT, tt);
            return place + " = " + ArithOp(ca.OperatorKind, place, X(ca.Value), tt);
        }

        static bool SimplePlace(string s) => System.Text.RegularExpressions.Regex.IsMatch(s, @"^[A-Za-z_][A-Za-z0-9_]*(\.\*|\.\?|\.[A-Za-z_][A-Za-z0-9_]*)*$");

        string IncStmt(IIncrementOrDecrementOperation inc)
        {
            bool up = inc.Kind == OperationKind.Increment;
            var t = inc.Target.Type!;
            if (inc.OperatorMethod != null)
            {
                var pl = Place(inc.Target);
                return pl + " = " + RuntimeOpCall(inc.OperatorMethod, new[] { pl });
            }
            if (IsCPtrElem(inc.Target, out var pe, out var pi))
                return "rt.cset(" + pe + ", " + pi + ", rt.cget(" + pe + ", " + pi + ") " + (up ? "+%" : "-%") + " 1)";
            var place = Place(inc.Target);
            if (!SimplePlace(place))
            {
                var ptr = Fresh("ip");
                return "{ const " + ptr + " = " + Addr(inc.Target) + "; " + ptr + ".* = " + StepValue(ptr + ".*", t, up) + "; }";
            }
            return place + " = " + StepValue(place, t, up);
        }

        string StepValue(string cur, ITypeSymbol t, bool up)
        {
            if (IsFloat(t)) return "(" + cur + (up ? " + 1.0" : " - 1.0") + ")";
            if (IsPtrType(t)) return "rt.padd(" + cur + ", " + (up ? "1" : "-1") + ")";
            return "(" + cur + (up ? " +% 1" : " -% 1") + ")";
        }

        static bool IsPtrType(ITypeSymbol t) => t is INamedTypeSymbol n && IsRuntime(n) && (n.Name == "CPtr" || StripArity(n.Name) == "Ptr");
    }
}

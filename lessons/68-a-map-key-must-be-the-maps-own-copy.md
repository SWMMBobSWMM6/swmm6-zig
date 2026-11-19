A container must keep its own copy of a string key, as C++ does: the Pascal runtime first stored the caller's string object, and every time series but the last one in a deck lost its name.

C++'s `std::unordered_map<std::string, ...>::operator[]` copies the key into the new node. In the C# port, a key is the
same object as the caller's unless the runtime copies it, and its `KeyCopy<T>` does that for every class of the runtime
(strings, vectors, pairs, paths), not for the engine's own classes (C++ pointers). The Pascal runtime's first `KeyCopy`
asked a virtual `IsLib` that only the path class answered `True`, so a string key was stored as the caller's object.
`TablesHandler` keeps one `current_name` string for the whole [TIMESERIES] section and passes it to
`TableData.add`, which does `by_name[id].push_back(idx)`; when the next series began, `current_name.assign(...)`
renamed the key inside the map, and only the last series could be found (deck `extran1_dummy.inp`: two of three
inflows were zero). The fix (`pascal/cpprt/rt_base.inc`) makes every class of the runtime's unit a library class:

```pascal
class function TCObj.IsLib: Boolean; begin Result := UnitName = 'cpprt'; end;
```

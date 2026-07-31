use assert_cmd::Command;

#[test]
fn helpers_take_empty_results_encode_as_json_arrays() {
    let script = r#"
local function iter(max)
  local index = 0
  return function()
    index = index + 1
    if index > max then return nil end
    return { n = index }
  end
end

local empty, empty_err = helpers.take(iter(0), 5)
if empty_err then error(empty_err.message) end
print(json.encode(empty))

local zero, zero_err = helpers.take(iter(3), 0)
if zero_err then error(zero_err.message) end
print(json.encode(zero))

local non_empty, non_empty_err = helpers.take(iter(1), 5)
if non_empty_err then error(non_empty_err.message) end
print(json.encode(non_empty))
"#;

    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .write_stdin(script)
        .assert()
        .success()
        .stdout("[]\n[]\n[[{\"n\":1}]]\n");
}

#[test]
fn helpers_page_empty_results_encode_as_json_arrays() {
    let script = r#"
local function iter(max)
  local index = 0
  return function()
    index = index + 1
    if index > max then return nil end
    return { n = index }
  end
end

local page, err = helpers.page(iter(0), 1, 10)
if err then error(err.message) end
print(json.encode(page))

local beyond, beyond_err = helpers.page(iter(1), 2, 10)
if beyond_err then error(beyond_err.message) end
print(json.encode(beyond))
"#;

    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .write_stdin(script)
        .assert()
        .success()
        .stdout("[]\n[]\n");
}

#[test]
fn helpers_page_returns_tuple_rows() {
    let script = r#"
local function iter()
  local keys = { "a", "b", "c", "d" }
  local values = { 1, 2, 3, 4 }
  local index = 0
  return function()
    index = index + 1
    if index > #keys then return nil end
    return keys[index], values[index]
  end
end

local page, err = helpers.page(iter(), 2, 2)
if err then error(err.message) end
print(json.encode(page))
"#;

    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .write_stdin(script)
        .assert()
        .success()
        .stdout("[[\"c\",3],[\"d\",4]]\n");
}

#[test]
fn helpers_collect_limit_zero_returns_an_empty_json_array() {
    let script = r#"
local function iter()
  local index = 0
  return function()
    index = index + 1
    if index > 3 then return nil end
    return index
  end
end

local items, err = helpers.collect(iter(), { limit = 0 })
if err then error(err.message) end
print(json.encode(items))

local all, all_err = helpers.collect(iter())
if all_err then error(all_err.message) end
print(json.encode(all))
"#;

    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .write_stdin(script)
        .assert()
        .success()
        .stdout("[]\n[[1],[2],[3]]\n");
}

#[test]
fn helpers_collect_and_take_accept_pair_style_iterators() {
    let script = r#"
local function pairs_iter()
  local keys = { "a", "b" }
  local values = { 1, 2 }
  local index = 0
  return function()
    index = index + 1
    if index > #keys then return nil end
    return keys[index], values[index]
  end
end

local collected, collected_err = helpers.collect(pairs_iter(), { limit = 2 })
if collected_err then error(collected_err.message) end
print(json.encode(collected))

local taken, taken_err = helpers.take(pairs_iter(), 2)
if taken_err then error(taken_err.message) end
print(json.encode(taken))
"#;

    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .write_stdin(script)
        .assert()
        .success()
        .stdout("[[\"a\",1],[\"b\",2]]\n[[\"a\",1],[\"b\",2]]\n");
}

#[test]
fn helpers_filter_find_and_collect_callbacks_receive_indexes() {
    let script = r#"
local filtered, filter_err = helpers.filter({"a","b","c"}, function(_value, index) return index == 2 end)
if filter_err then error(filter_err.message) end
print(json.encode(filtered))

local found, find_err = helpers.find({"a","b","c"}, function(_value, index) return index == 2 end)
if find_err then error(find_err.message) end
print(found)

local function iter()
  local items = {"a","b","c"}
  local index = 0
  return function()
    index = index + 1
    return items[index]
  end
end

local collected, collect_err = helpers.collect(iter(), {
  filter = function(row, index) return row[1] ~= nil and index >= 2 end,
  transform = function(row, index) return { row[1] .. ":" .. index } end,
})
if collect_err then error(collect_err.message) end
print(json.encode(collected))
"#;

    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .write_stdin(script)
        .assert()
        .success()
        .stdout("[\"b\"]\nb\n[[\"b:2\"],[\"c:3\"]]\n");
}

#[test]
fn helpers_first_and_collect_preserve_iterator_tuples() {
    let script = r#"
local function single_values()
  local values = {"a", "b"}
  local index = 0
  return function()
    index = index + 1
    return values[index]
  end
end

local collected, collected_err = helpers.collect(single_values())
if collected_err then error(collected_err.message) end
print(json.encode(collected))

local first, first_err = helpers.first(single_values())
if first_err then error(first_err.message) end
print(json.encode(first), first.n)

local function with_nil()
  local done = false
  return function()
    if done then return nil, "ignored" end
    done = true
    return "a", nil, 3
  end
end

local tuple, tuple_err = helpers.first(with_nil())
if tuple_err then error(tuple_err.message) end
print(tuple[1], tuple[2] == nil, tuple[3], tuple.n)
print(json.encode(tuple))

local collected_nil, collected_nil_err = helpers.collect(with_nil())
if collected_nil_err then error(collected_nil_err.message) end
print(json.encode(collected_nil))

local empty, empty_err = helpers.first(function() return nil, "ignored" end)
if empty_err then error(empty_err.message) end
print(empty == nil)
"#;

    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .write_stdin(script)
        .assert()
        .success()
        .stdout("[[\"a\"],[\"b\"]]\n[\"a\"]\t1\na\ttrue\t3\t3\n[\"a\",null,3]\n[[\"a\",null,3]]\ntrue\n");
}

#[test]
fn json_encode_uses_marked_array_n_without_treating_object_n_as_array() {
    let script = r#"
print(json.encode({"a", "b", "c"}))

local tuple = json._mark_array({"a", nil, 3, n = 3})
print(json.encode(tuple))

print(json.encode({name = "test", n = 3}))
"#;

    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .write_stdin(script)
        .assert()
        .success()
        .stdout("[\"a\",\"b\",\"c\"]\n[\"a\",null,3]\n{\"n\":3,\"name\":\"test\"}\n");
}

#[test]
fn json_decode_marks_arrays_so_they_roundtrip_with_nulls_and_empty_arrays() {
    let script = r#"
local empty = json.decode("[]")
print(json.encode(empty), empty.n)

local tuple = json.decode('["a", null, 3]')
print(json.encode(tuple), tuple.n)

local object = json.decode('{"name":"test","n":3}')
print(json.encode(object))
"#;

    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .write_stdin(script)
        .assert()
        .success()
        .stdout("[]\t0\n[\"a\",null,3]\t3\n{\"n\":3,\"name\":\"test\"}\n");
}

#[test]
fn helpers_string_predicates_return_structured_errors_for_nil_inputs() {
    let script = r#"
local contains_result, contains_err = helpers.contains(nil, "x")
print(contains_result == nil, contains_err and contains_err.code)

local starts_result, starts_err = helpers.starts_with(nil, "x")
print(starts_result == nil, starts_err and starts_err.code)
"#;

    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .write_stdin(script)
        .assert()
        .success()
        .stdout("true\tINVALID_FIELD_VALUE\ntrue\tINVALID_FIELD_VALUE\n");
}

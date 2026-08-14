use mcp_server::storage::Store;

#[test]
fn sqlite_store_keeps_kv_expiry_metrics_and_snippets_separate() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("store.db");
    let store = Store::open(Some(&path)).unwrap();

    store
        .put_kv(
            "cache",
            "live",
            &serde_json::json!({"ok": true}),
            "json",
            None,
            None,
        )
        .unwrap();
    store
        .put_kv(
            "cache",
            "expired",
            &serde_json::json!(1),
            "json",
            None,
            Some(0),
        )
        .unwrap();
    assert_eq!(
        store.get_kv("cache", "live").unwrap(),
        Some(serde_json::json!({"ok": true}))
    );
    assert_eq!(store.get_kv("cache", "expired").unwrap(), None);
    assert_eq!(store.keys_kv("cache").unwrap(), ["live"]);

    assert_eq!(store.increment_metric("fn.core.calls", 1.0).unwrap(), 1.0);
    assert_eq!(store.increment_metric("fn.core.calls", 2.0).unwrap(), 3.0);
    assert_eq!(store.list_metrics().unwrap()[0].value, 3.0);

    store
        .save_snippet(
            "local.answer",
            "function() return 42 end",
            None,
            None,
            Some("answer"),
        )
        .unwrap();
    let snippet = store.get_snippet("local.answer").unwrap().unwrap();
    assert_eq!(snippet.code, "function() return 42 end");
    assert_eq!(snippet.description, "answer");
    assert_eq!(store.keys_kv("cache").unwrap(), ["live"]);

    drop(store);
    let reopened = Store::open(Some(&path)).unwrap();
    assert!(reopened.get_snippet("local.answer").unwrap().is_some());
}

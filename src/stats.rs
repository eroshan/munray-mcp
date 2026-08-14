use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
};

use anyhow::Result;
use serde::Serialize;

use crate::{runtime::LuaRuntime, storage::Store};

const TOP_FUNCTION_LIMIT: usize = 20;

#[derive(Clone, Debug, Default, Serialize)]
pub struct FunctionStat {
    pub path: String,
    pub service: String,
    pub available: bool,
    pub used: bool,
    pub calls: f64,
    pub errors: f64,
    pub blocked: f64,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct ServiceStat {
    pub name: String,
    pub available: usize,
    pub used: usize,
    pub unused: usize,
    pub calls: f64,
    pub errors: f64,
    pub blocked: f64,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Summary {
    pub available_functions: usize,
    pub used_functions: usize,
    pub unused_functions: usize,
    pub total_calls: f64,
    pub total_errors: f64,
    pub total_blocked: f64,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Report {
    pub store_path: PathBuf,
    pub summary: Summary,
    pub services: Vec<ServiceStat>,
    pub functions: Vec<FunctionStat>,
    pub unused: Vec<String>,
}

pub fn collect_report(service_dir: Option<&Path>, store_path: &Path) -> Result<Report> {
    let runtime = LuaRuntime::new_persistent(service_dir, store_path)?;
    let available = runtime.eligible_function_paths()?;
    let metrics = collect_metrics(store_path)?;
    Ok(build_report(store_path.to_path_buf(), available, metrics))
}

fn collect_metrics(store_path: &Path) -> Result<HashMap<String, FunctionStat>> {
    let mut out = HashMap::new();
    for entry in Store::open(Some(store_path))?.list_metrics()? {
        let Some((path, metric)) = parse_metric_key(&entry.name) else {
            continue;
        };
        let stat = out.entry(path.to_owned()).or_insert_with(|| FunctionStat {
            path: path.to_owned(),
            service: service_from_path(path).to_owned(),
            ..FunctionStat::default()
        });
        match metric {
            "calls" => stat.calls = entry.value,
            "err" => stat.errors = entry.value,
            "blocked" => stat.blocked = entry.value,
            _ => {}
        }
    }
    Ok(out)
}

fn parse_metric_key(key: &str) -> Option<(&str, &str)> {
    let rest = key.strip_prefix("fn.")?;
    for suffix in [".calls", ".err", ".blocked"] {
        if let Some(path) = rest.strip_suffix(suffix) {
            if path.is_empty() {
                return None;
            }
            return Some((path, &suffix[1..]));
        }
    }
    None
}

fn build_report(
    store_path: PathBuf,
    available: Vec<String>,
    metrics: HashMap<String, FunctionStat>,
) -> Report {
    let mut report = Report {
        store_path,
        ..Report::default()
    };
    let mut service_stats = HashMap::<String, ServiceStat>::new();
    let mut available_paths = HashSet::new();

    for path in available {
        available_paths.insert(path.clone());
        let mut stat = metrics.get(&path).cloned().unwrap_or_else(|| FunctionStat {
            path: path.clone(),
            service: service_from_path(&path).to_owned(),
            ..FunctionStat::default()
        });
        if stat.path.is_empty() {
            stat.path = path.clone();
        }
        if stat.service.is_empty() {
            stat.service = service_from_path(&path).to_owned();
        }
        stat.available = true;
        stat.used = stat.calls > 0.0;

        report.summary.available_functions += 1;
        report.summary.total_calls += stat.calls;
        report.summary.total_errors += stat.errors;
        report.summary.total_blocked += stat.blocked;

        let service = service_stats
            .entry(stat.service.clone())
            .or_insert_with(|| ServiceStat {
                name: stat.service.clone(),
                ..ServiceStat::default()
            });
        service.available += 1;
        service.calls += stat.calls;
        service.errors += stat.errors;
        service.blocked += stat.blocked;

        if stat.used {
            report.summary.used_functions += 1;
            service.used += 1;
        } else {
            report.summary.unused_functions += 1;
            service.unused += 1;
            report.unused.push(stat.path.clone());
        }

        report.functions.push(stat);
    }

    for (path, mut stat) in metrics {
        if available_paths.contains(&path)
            || (stat.calls == 0.0 && stat.errors == 0.0 && stat.blocked == 0.0)
        {
            continue;
        }
        if stat.path.is_empty() {
            stat.path = path.clone();
        }
        if stat.service.is_empty() {
            stat.service = service_from_path(&path).to_owned();
        }
        stat.available = false;
        stat.used = stat.calls > 0.0;

        report.summary.total_calls += stat.calls;
        report.summary.total_errors += stat.errors;
        report.summary.total_blocked += stat.blocked;

        let service = service_stats
            .entry(stat.service.clone())
            .or_insert_with(|| ServiceStat {
                name: stat.service.clone(),
                ..ServiceStat::default()
            });
        if stat.used {
            service.used += 1;
        }
        service.calls += stat.calls;
        service.errors += stat.errors;
        service.blocked += stat.blocked;

        report.functions.push(stat);
    }

    report.services = service_stats.into_values().collect();
    report
        .functions
        .sort_by(|left, right| left.path.cmp(&right.path));
    report
        .services
        .sort_by(|left, right| left.name.cmp(&right.name));
    report.unused.sort_by(|left, right| {
        let left_service = service_from_path(left);
        let right_service = service_from_path(right);
        left_service
            .cmp(right_service)
            .then_with(|| left.cmp(right))
    });

    report
}

fn service_from_path(path: &str) -> &str {
    path.split_once('.').map_or(path, |(service, _)| service)
}

pub fn render_text(report: &Report) -> String {
    let mut out = String::new();
    out.push_str("Function usage stats\n");
    out.push_str(&format!("Store: {}\n\n", report.store_path.display()));

    let coverage = if report.summary.available_functions > 0 {
        report.summary.used_functions as f64 / report.summary.available_functions as f64 * 100.0
    } else {
        0.0
    };
    out.push_str(&format!(
        "Summary\n  Available functions: {}\n  Used functions: {}\n  Unused functions: {}\n  Coverage: {:.1}%\n  Total calls: {}\n  Total errors: {}\n  Total blocked: {}\n\n",
        report.summary.available_functions,
        report.summary.used_functions,
        report.summary.unused_functions,
        coverage,
        format_number(report.summary.total_calls),
        format_number(report.summary.total_errors),
        format_number(report.summary.total_blocked),
    ));

    out.push_str("By service\n");
    let mut service_rows = report.services.clone();
    service_rows.sort_by(|left, right| {
        right
            .calls
            .total_cmp(&left.calls)
            .then_with(|| left.name.cmp(&right.name))
    });
    let mut rows = vec![vec![
        "SERVICE".to_owned(),
        "AVAILABLE".to_owned(),
        "USED".to_owned(),
        "UNUSED".to_owned(),
        "CALLS".to_owned(),
        "ERRORS".to_owned(),
        "BLOCKED".to_owned(),
    ]];
    if service_rows.is_empty() {
        rows.push(vec![
            "(none)".to_owned(),
            String::new(),
            String::new(),
            String::new(),
            String::new(),
            String::new(),
            String::new(),
        ]);
    } else {
        for service in service_rows {
            rows.push(vec![
                service.name,
                service.available.to_string(),
                service.used.to_string(),
                service.unused.to_string(),
                format_number(service.calls),
                format_number(service.errors),
                format_number(service.blocked),
            ]);
        }
    }
    push_table(&mut out, &rows);
    out.push('\n');

    out.push_str(&format!(
        "Top functions by calls (top {TOP_FUNCTION_LIMIT})\n"
    ));
    let mut functions = report.functions.clone();
    functions.sort_by(|left, right| {
        right
            .calls
            .total_cmp(&left.calls)
            .then_with(|| left.path.cmp(&right.path))
    });
    functions.truncate(TOP_FUNCTION_LIMIT);
    let mut rows = vec![vec![
        "FUNCTION".to_owned(),
        "CALLS".to_owned(),
        "ERRORS".to_owned(),
        "BLOCKED".to_owned(),
    ]];
    if functions.is_empty() {
        rows.push(vec![
            "(none)".to_owned(),
            String::new(),
            String::new(),
            String::new(),
        ]);
    } else {
        for function in functions {
            rows.push(vec![
                function.path,
                format_number(function.calls),
                format_number(function.errors),
                format_number(function.blocked),
            ]);
        }
    }
    push_table(&mut out, &rows);
    out.push('\n');

    out.push_str(&format!("Never used functions ({})\n", report.unused.len()));
    if report.unused.is_empty() {
        out.push_str("  (none)\n");
    } else {
        for path in &report.unused {
            out.push_str("  ");
            out.push_str(path);
            out.push('\n');
        }
    }

    out
}

fn push_table(out: &mut String, rows: &[Vec<String>]) {
    let columns = rows.iter().map(Vec::len).max().unwrap_or(0);
    let mut widths = vec![0; columns];
    for row in rows {
        for (index, cell) in row.iter().enumerate() {
            widths[index] = widths[index].max(cell.len());
        }
    }
    for row in rows {
        for (index, width) in widths.iter().enumerate().take(columns) {
            let cell = row.get(index).map(String::as_str).unwrap_or("");
            out.push_str(cell);
            if index + 1 < columns {
                for _ in 0..(width.saturating_sub(cell.len()) + 2) {
                    out.push(' ');
                }
            }
        }
        out.push('\n');
    }
}

fn format_number(value: f64) -> String {
    if value.trunc() == value {
        format!("{}", value as i64)
    } else {
        value.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_text_matches_legacy_shape() {
        let report = Report {
            store_path: PathBuf::from("/tmp/store.db"),
            summary: Summary {
                available_functions: 2,
                used_functions: 1,
                unused_functions: 1,
                total_calls: 7.0,
                total_errors: 1.0,
                total_blocked: 0.0,
            },
            services: vec![ServiceStat {
                name: "gitlab".to_owned(),
                available: 2,
                used: 1,
                unused: 1,
                calls: 7.0,
                errors: 1.0,
                blocked: 0.0,
            }],
            functions: vec![
                FunctionStat {
                    path: "gitlab.job.log".to_owned(),
                    calls: 7.0,
                    errors: 1.0,
                    ..FunctionStat::default()
                },
                FunctionStat {
                    path: "gitlab.repo.get".to_owned(),
                    ..FunctionStat::default()
                },
            ],
            unused: vec!["gitlab.repo.get".to_owned()],
        };

        let out = render_text(&report);
        assert!(out.contains("Function usage stats\nStore: /tmp/store.db"));
        assert!(out.contains("Coverage: 50.0%"));
        assert!(out.contains("Top functions by calls (top 20)"));
        assert!(out.contains("Never used functions (1)\n  gitlab.repo.get\n"));
    }

    #[test]
    fn build_report_includes_historical_only_metrics_in_usage_totals() {
        let mut metrics = HashMap::new();
        metrics.insert(
            "gitlab.job.log".to_owned(),
            FunctionStat {
                path: "gitlab.job.log".to_owned(),
                service: "gitlab".to_owned(),
                calls: 7.0,
                errors: 1.0,
                ..FunctionStat::default()
            },
        );
        metrics.insert(
            "old.removed.fn".to_owned(),
            FunctionStat {
                path: "old.removed.fn".to_owned(),
                service: "old".to_owned(),
                calls: 999.0,
                errors: 12.0,
                blocked: 3.0,
                ..FunctionStat::default()
            },
        );

        let report = build_report(
            PathBuf::from("/tmp/store.db"),
            vec![
                "gitlab.job.log".to_owned(),
                "gitlab.repo.get".to_owned(),
                "slack.msg.send".to_owned(),
            ],
            metrics,
        );

        assert_eq!(report.summary.available_functions, 3);
        assert_eq!(report.summary.used_functions, 1);
        assert_eq!(report.summary.unused_functions, 2);
        assert_eq!(report.summary.total_calls, 1006.0);
        assert_eq!(report.summary.total_errors, 13.0);
        assert_eq!(report.summary.total_blocked, 3.0);
        assert_eq!(report.unused, ["gitlab.repo.get", "slack.msg.send"]);
        assert!(
            report
                .functions
                .iter()
                .any(|function| function.path == "old.removed.fn"
                    && !function.available
                    && function.used
                    && function.calls == 999.0)
        );
        assert!(report.services.iter().any(|service| service.name == "old"
            && service.available == 0
            && service.used == 1
            && service.calls == 999.0));
    }
}

using System.Text.Json;
using System.Text.RegularExpressions;
using Dapper;
using Npgsql;
using TH.IDR.ClaimSelection.Api.Database;

namespace TH.IDR.ClaimSelection.Api;

public sealed record ConfigWrite(Dictionary<string, JsonElement>? Values, Dictionary<string, JsonElement>? Key);

/// <summary>
/// Generic editor for the config_* tables of the Claim Selection schema. Column names, types and keys come from the
/// database catalog, values are sent as text parameters and cast to the column type, so nothing is concatenated from user input.
/// Every write runs with idr_core.user_id set, so the audit trigger records who changed what (config_version_audit).
/// </summary>
public static class ConfigApi
{
    private sealed record Col(string Name, string Type, bool Nullable, bool Generated, bool HasDefault);

    private static readonly Regex Safe = new("^[a-z0-9_]+$", RegexOptions.Compiled);

    public static void MapConfig(this RouteGroupBuilder api)
    {
        api.MapGet("/config/tables", async (IDbConnectionFactory ds) =>
        {
            var tables = await ds.RowsAsync(
                """
                SELECT t.table_name AS name,
                       EXISTS (SELECT 1 FROM information_schema.columns c WHERE c.table_schema = t.table_schema AND c.table_name = t.table_name AND c.column_name = 'client_id') AS has_client
                FROM information_schema.tables t
                WHERE t.table_schema = 'idr_core' AND t.table_name LIKE 'config\_%' AND t.table_name <> 'config_version_audit'
                ORDER BY t.table_name
                """);
            foreach (var t in tables)
            {
                var name = (string)t["name"]!;
                t["rows"] = await ds.ScalarAsync<long>($"SELECT count(*) FROM idr_core.\"{name}\"");
            }

            return tables;
        });

        api.MapGet("/config/audit", async (IDbConnectionFactory ds, string? category) =>
            await ds.RowsAsync(
                """
                SELECT changed_at_utc, user_id, category, record_key, field_name, prior_value, new_value
                FROM idr_core.config_version_audit
                WHERE (@category::text IS NULL OR category = @category)
                ORDER BY config_version_audit_id DESC LIMIT 300
                """, new { category }));

        api.MapGet("/config/{table}", async (IDbConnectionFactory ds, string table, string? client, string? search) =>
        {
            var meta = await LoadAsync(ds, table);
            if (meta is null) return Results.NotFound(new { error = $"Unknown configuration table '{table}'." });
            var (cols, pk) = meta.Value;
            var hasClient = cols.Any(c => c.Name == "client_id");
            var order = pk.Count > 0 ? string.Join(", ", pk.Select(p => $"t.\"{p}\"")) : "1";
            var sql = $"""
                SELECT t.* FROM idr_core."{table}" t
                WHERE (@client::text IS NULL OR {(hasClient ? "t.client_id = @client" : "true")})
                  AND (@search::text IS NULL OR t::text ILIKE @search)
                ORDER BY {order} LIMIT 300
                """;
            var rows = await ds.RowsAsync(sql, new { client = string.IsNullOrWhiteSpace(client) ? null : client, search = string.IsNullOrWhiteSpace(search) ? null : "%" + search + "%" });
            return Results.Ok(new
            {
                table,
                columns = cols.Select(c => new { name = c.Name, type = c.Type, nullable = c.Nullable, generated = c.Generated, has_default = c.HasDefault }),
                key = pk,
                has_client = hasClient,
                rows
            });
        });

        api.MapPost("/config/{table}", (IDbConnectionFactory ds, string table, ConfigWrite body) =>
            WriteAsync(ds, table, async (conn, tx, cols, pk) =>
            {
                var values = Clean(body.Values, cols, skipEmpty: true);
                if (values.Count == 0) throw new ArgumentException("Enter at least one value.");
                var names = values.Keys.ToList();
                var p = new DynamicParameters();
                for (var i = 0; i < names.Count; i++) p.Add($"p{i}", values[names[i]]);
                var sql = $"INSERT INTO idr_core.\"{table}\" ({string.Join(", ", names.Select(n => $"\"{n}\""))}) " +
                          $"VALUES ({string.Join(", ", names.Select((n, i) => $"CAST(@p{i} AS {cols.First(c => c.Name == n).Type})"))})";
                await conn.ExecuteAsync(sql, p, tx);
            }));

        api.MapPut("/config/{table}", (IDbConnectionFactory ds, string table, ConfigWrite body) =>
            WriteAsync(ds, table, async (conn, tx, cols, pk) =>
            {
                if (pk.Count == 0) throw new ArgumentException("This table has no key and can not be edited.");
                var key = Clean(body.Key, cols, skipEmpty: false);
                if (pk.Any(k => !key.ContainsKey(k) || key[k] is null)) throw new ArgumentException("The row key is missing.");
                var values = Clean(body.Values, cols, skipEmpty: false).Where(kv => !pk.Contains(kv.Key)).ToList();
                if (values.Count == 0) throw new ArgumentException("Nothing to change.");
                var p = new DynamicParameters();
                var sets = new List<string>();
                for (var i = 0; i < values.Count; i++)
                {
                    p.Add($"v{i}", values[i].Value);
                    sets.Add($"\"{values[i].Key}\" = CAST(@v{i} AS {cols.First(c => c.Name == values[i].Key).Type})");
                }

                var wheres = new List<string>();
                for (var i = 0; i < pk.Count; i++)
                {
                    p.Add($"k{i}", key[pk[i]]);
                    wheres.Add($"\"{pk[i]}\" = CAST(@k{i} AS {cols.First(c => c.Name == pk[i]).Type})");
                }

                var n = await conn.ExecuteAsync($"UPDATE idr_core.\"{table}\" SET {string.Join(", ", sets)} WHERE {string.Join(" AND ", wheres)}", p, tx);
                if (n == 0) throw new ArgumentException("The row no longer exists.");
            }));

        api.MapPost("/config/{table}/delete", (IDbConnectionFactory ds, string table, ConfigWrite body) =>
            WriteAsync(ds, table, async (conn, tx, cols, pk) =>
            {
                if (pk.Count == 0) throw new ArgumentException("This table has no key and can not be edited.");
                var key = Clean(body.Key, cols, skipEmpty: false);
                var p = new DynamicParameters();
                var wheres = new List<string>();
                for (var i = 0; i < pk.Count; i++)
                {
                    if (!key.TryGetValue(pk[i], out var v) || v is null) throw new ArgumentException("The row key is missing.");
                    p.Add($"k{i}", v);
                    wheres.Add($"\"{pk[i]}\" = CAST(@k{i} AS {cols.First(c => c.Name == pk[i]).Type})");
                }

                await conn.ExecuteAsync($"DELETE FROM idr_core.\"{table}\" WHERE {string.Join(" AND ", wheres)}", p, tx);
            }));
    }

    private static async Task<IResult> WriteAsync(IDbConnectionFactory ds, string table,
        Func<NpgsqlConnection, NpgsqlTransaction, List<Col>, List<string>, Task> action)
    {
        var meta = await LoadAsync(ds, table);
        if (meta is null) return Results.NotFound(new { error = $"Unknown configuration table '{table}'." });
        await using var conn = await ds.OpenConnectionAsync();
        await using var tx = await conn.BeginTransactionAsync();
        try
        {
            await conn.ExecuteAsync("SELECT set_config('idr_core.user_id', 'demo-ui', true)", transaction: tx);
            await action(conn, tx, meta.Value.Item1, meta.Value.Item2);
            await tx.CommitAsync();
            return Results.Ok(new { ok = true });
        }
        catch (ArgumentException e)
        {
            return Results.BadRequest(new { error = e.Message });
        }
        catch (PostgresException e)
        {
            return Results.BadRequest(new { error = e.MessageText + (e.Detail is null ? "" : " - " + e.Detail) });
        }
    }

    private static Dictionary<string, string?> Clean(Dictionary<string, JsonElement>? input, List<Col> cols, bool skipEmpty)
    {
        var result = new Dictionary<string, string?>();
        foreach (var (name, el) in input ?? [])
        {
            var col = cols.FirstOrDefault(c => c.Name == name) ?? throw new ArgumentException($"Unknown column '{name}'.");
            string? text = el.ValueKind switch
            {
                JsonValueKind.Null or JsonValueKind.Undefined => null,
                JsonValueKind.String => el.GetString(),
                _ => el.ToString()
            };
            if (string.IsNullOrWhiteSpace(text))
            {
                if (skipEmpty) continue;
                text = null;
            }

            if (col.Generated && skipEmpty) continue;
            result[col.Name] = text?.Trim();
        }

        return result;
    }

    private static async Task<(List<Col>, List<string>)?> LoadAsync(IDbConnectionFactory ds, string table)
    {
        if (!Safe.IsMatch(table) || !table.StartsWith("config_") || table == "config_version_audit") return null;
        var rows = await ds.RowsAsync(
            """
            SELECT column_name, udt_name, is_nullable = 'YES' AS nullable,
                   (is_identity = 'YES' OR COALESCE(column_default LIKE 'nextval%', false)) AS generated, column_default IS NOT NULL AS has_default
            FROM information_schema.columns WHERE table_schema = 'idr_core' AND table_name = @table ORDER BY ordinal_position
            """, new { table });
        if (rows.Count == 0) return null;
        var cols = rows.Select(r => new Col((string)r["column_name"]!, (string)r["udt_name"]!, (bool)r["nullable"]!, (bool)r["generated"]!, (bool)r["has_default"]!)).ToList();
        if (cols.Any(c => !Safe.IsMatch(c.Name) || !Safe.IsMatch(c.Type))) return null;
        var pk = (await ds.RowsAsync(
            """
            SELECT a.attname AS name FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
            WHERE i.indrelid = ('idr_core.' || quote_ident(@table))::regclass AND i.indisprimary
            ORDER BY array_position(i.indkey::int2[], a.attnum)
            """, new { table })).Select(r => (string)r["name"]!).ToList();
        return (cols, pk);
    }
}

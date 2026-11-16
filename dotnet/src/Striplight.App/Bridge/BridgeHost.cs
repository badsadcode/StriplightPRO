using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Striplight.App.Bridge;

/// <summary>Raised by a handler for a problem the user should see as a plain message.</summary>
public sealed class BridgeException(string message) : Exception(message);

/// <summary>
/// JSON message bridge between the WebView2 page and .NET.
///
///   page → host : { "id": 7, "cmd": "project.open", "args": { ... } }
///   host → page : { "id": 7, "ok": true, "result": ... }  or  { "id": 7, "ok": false, "error": "..." }
///   host → page : { "event": "export.progress", "data": ... }   (unsolicited)
///
/// Handlers run on the UI thread (WebMessageReceived is raised there) and may await.
/// The page side lives in wwwroot/js/bridge.js.
/// </summary>
public sealed class BridgeHost
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
    };

    private readonly Dictionary<string, Func<JsonElement, Task<object?>>> _handlers = new(StringComparer.Ordinal);

    /// <summary>Serialised messages (events) to post to the page.</summary>
    public event Action<string>? Outgoing;

    public void OnAsync(string cmd, Func<JsonElement, Task<object?>> handler) => _handlers[cmd] = handler;

    public void On(string cmd, Func<JsonElement, object?> handler) =>
        _handlers[cmd] = args => Task.FromResult(handler(args));

    public void Emit(string evt, object? data) =>
        Outgoing?.Invoke(JsonSerializer.Serialize(new { @event = evt, data }, Json));

    public async Task<string> HandleAsync(string messageJson)
    {
        long id = 0;
        try
        {
            using var doc = JsonDocument.Parse(messageJson);
            var root = doc.RootElement;
            id = root.TryGetProperty("id", out var idEl) ? idEl.GetInt64() : 0;
            string cmd = root.GetProperty("cmd").GetString() ?? "";
            var args = root.TryGetProperty("args", out var a) ? a.Clone() : default;

            if (!_handlers.TryGetValue(cmd, out var handler))
                return Reply(id, false, null, $"Unknown command '{cmd}'.");
            object? result = await handler(args);
            return Reply(id, true, result, null);
        }
        catch (Exception ex) when (ex is BridgeException or IOException or UnauthorizedAccessException
                                       or InvalidOperationException or ArgumentException or JsonException
                                       or KeyNotFoundException or FormatException)
        {
            return Reply(id, false, null, ex.Message);
        }
        catch (Exception ex)
        {
            // Never leave the page waiting for a reply that does not come: report anything unexpected.
            return Reply(id, false, null, $"Unexpected error ({ex.GetType().Name}): {ex.Message}");
        }
    }

    private static string Reply(long id, bool ok, object? result, string? error) =>
        JsonSerializer.Serialize(new { id, ok, result, error }, Json);

    // ---- argument helpers -------------------------------------------------

    public static T Arg<T>(JsonElement args, string name, T fallback)
    {
        if (args.ValueKind != JsonValueKind.Object || !args.TryGetProperty(name, out var v) ||
            v.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
            return fallback;
        return v.Deserialize<T>(Json) ?? fallback;
    }

    public static T Args<T>(JsonElement args) where T : new() =>
        args.ValueKind == JsonValueKind.Object ? args.Deserialize<T>(Json) ?? new T() : new T();
}

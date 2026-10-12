using StackExchange.Redis;

var builder = WebApplication.CreateBuilder(args);

// Supplied by docker-compose.yml via the ConnectionStrings__Redis environment variable
var redisConnection = builder.Configuration.GetConnectionString("Redis") ?? "localhost:6379,abortConnect=false";
builder.Services.AddSingleton<IConnectionMultiplexer>(_ => ConnectionMultiplexer.Connect(redisConnection));

var app = builder.Build();

// Increments a counter held in Redis and reports which container handled the request
app.MapGet("/api/visits", async (IConnectionMultiplexer redis) =>
{
    var visits = await redis.GetDatabase().StringIncrementAsync("visits");
    return Results.Ok(new { visits, servedBy = Environment.MachineName });
});

// Liveness: is the process able to serve requests at all? Deliberately has no dependencies.
app.MapGet("/health", () => Results.Ok("healthy"));

// Readiness: can this instance do useful work right now? Checks its dependency (Redis).
app.MapGet("/health/ready", async (IConnectionMultiplexer redis) =>
{
    try
    {
        await redis.GetDatabase().PingAsync();
        return Results.Ok("ready");
    }
    catch (RedisException)
    {
        return Results.StatusCode(StatusCodes.Status503ServiceUnavailable);
    }
});

app.Run();

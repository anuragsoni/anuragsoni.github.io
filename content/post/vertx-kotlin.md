+++
title = "Using Kotlin Coroutines with Vert.x"
date = 2022-09-15

[taxonomies]
tags = ["Kotlin"]
+++

[Vert.x](https://vertx.io) is a toolkit for writing asynchronous and reactive applications on the JVM. The Vert.x ecosystem has high-quality libraries providing support for web services, database drivers, authentication, and more.

I've recently started to use Vert.x, but I chose to use it with Kotlin instead of Java. I'm still in my first week of using Kotlin, but I'm finding the language very pleasant so far. This post will talk about Vert.x Web which is a library that builds on top of the core Vert.x library to provide everything one would need to write an HTTP/HTTP2 service. It is similar in spirit to Sinatra from the Ruby world, or Flask from Python.

Vert.x is a fully concurrent/asynchronous toolkit and it offers a few different units of abstractions to help make this approachable. When using the library with Java, callbacks, promises and futures are available and should feel very familiar to anyone used to Javascript, Async/Lwt from OCaml, etc. While promises and futures work well, I am using Vert.x with Kotlin so I wanted to use coroutines as the unit of concurrency, and benefit from being able to write my async operations in direct-style. This is where I ran into some gaps in the Vert.x HTTP library.

Vert.x's Kotlin support is in the form of a library that implements some functions that allow one to `await` a Vert.x Future from within a kotlin coroutine. Beyond this, Kotlin users access the same Vert.x APIs that are used from Java that is designed around promises and futures. When writing client code, it was easy to use the `await` implementations from the vertx-kotlin support library from within a kotlin coroutine, but it took me a while to figure out a satisfactory solution that allows defining HTTP handlers that are kotlin coroutines, thus allowing the handlers to consume other Kotlin APIs that work with coroutines instead of vert.x promises and futures.

As an example, creating a router using the default API from Vert.x Web looks like this:

```kotlin
val router = Router.router(vertx);

router.route("/hello").handler { requestContext ->
    requestContext.response().send("Hello World")
}
```

For simple handlers, and if the APIs that are needed within the handler use promises/callbacks, then this works just fine. While promises work fine, the callback style APIs can be a little difficult to read, and one big perk of using Kotlin is its support for coroutines that help write direct-style asynchronous code. It is fairly common to see coroutines used in Kotlin libraries, so it was important for me to find a way to write HTTP handlers that can work with coroutines seamlessly.

We will simulate some async work using a simple suspendable function that sleeps for a duration before responding.

```kotlin
suspend fun coroutineDemo(): String {
    delay(3000)
    return "Hello World"
}
```

Trying to call `coroutineDemo()` within the vert.x route handler will result in an error saying that `Suspension functions can be called only within the coroutine body`. What we need is a way to define a new kind of route handler that allows users to provide a suspendable function as a handler and transforms it into a callback-based handler that Vert.x Web understands. Lucky for us Kotlin comes with a pretty neat way to extend third-party libraries, called [Extensions](https://kotlinlang.org/docs/extensions.html). With extensions, we can extend the Vert.x Route interface to add a new handler type that works with coroutines.

```kotlin
fun Route.coroutineHandler(
    coroutineContext: CoroutineContext,
    userHandler: suspend (RoutingContext) -> Unit
) = handler { routingContext ->
    CoroutineScope(coroutineContext).launch {
        try {
            userHandler(routingContext)
        } catch (exception: Exception) {
            routingContext.fail(exception)
        }
    }
}
```

This is a short but fairly dense function. Starting at the top we can see:

- A [CoroutineContext](https://kotlinlang.org/api/latest/jvm/stdlib/kotlin.coroutines/-coroutine-context/) since every kotlin coroutine executes within a context, and we'd like to allow the user to forward the context set up by the vertx-kotlin library.
- A `userHandler` that is similar to the default handler type `(RoutingContext -> Unit)`, but is a suspendable function instead.
- We create a new Vert.x route handler, set up a new [CoroutineScope](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-coroutine-scope/) that is used to launch the suspendable handler.
- We catch any unhandled exceptions and forward them to the vert.x router context so it can mark the request as a failure, call the vert.x error handler, and send an appropriate error response to the user.

With this extension function in place, we can now add suspendable handlers to the vert.x router:

```kotlin
val router = Router.router(vertx);

router.route("/hello").coroutineHandler(coroutineContext) { routingContext ->
    val payload = coroutineDemo()
    routingContext.response().send(payload)
}
```

The coroutineContext referenced in this snippet is the context available in a class that extends [CoroutineVerticle](https://vertx.io/docs/vertx-lang-kotlin-coroutines/kotlin/#_extending_coroutineverticle).

That is all for this post! This took a few tries for me to figure out as a new Kotlin user, and hopefully, some of you will find this useful! If you like this post or have feedback do let me know, either via [email](mailto:github@sonianurag.com) or on [github](https://github.com/anuragsoni/anuragsoni.github.io/discussions).

All the code in this post can be found [here](https://gist.github.com/anuragsoni/3680b9c30ba07ff16896490310c4fa7a).
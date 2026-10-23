# Framework modular de objetos en Ruby 4.0.8

## 1. Objetivo y decisiones

Construir un framework desde cero, inspirado en la colaboración entre objetos de Smalltalk, con controllers por transporte, UseCases invocables y persistencia mediante Data Mapper.

- **Ruby 4.0.8** como versión exacta del proyecto.
- Ruby core y biblioteca estándar para infraestructura, concurrencia, JSON, sockets, TLS y observabilidad.
- Primera entrega con **HTTP/1.1, API JSON y almacenamiento HashMap**.
- Siguiente adaptador de persistencia: SQLite, permitiendo `sqlite3` como única gem externa.
- Un **Thread nuevo por request admitido**, con contexto de ejecución propio.
- Excepciones específicas para comunicar fallos esperados.
- Ante rollback se descartan la sesión y sus objetos; los resultados públicos son valores independientes.
- Ruby Box, Ractor y ZJIT se incorporan como capacidades opcionales.

El nombre técnico inicial será `ObjectFramework`. El plan se guarda en `/home/gaston/Code/ruby-object-framework/PLAN.md`.

## 2. Modelo de objetos y capa web

### Módulos y responsabilidades

Los módulos publican protocolos pequeños, reciben colaboradores por constructor y registran fábricas explícitas.

| Objeto o colaboración | Responsabilidad |
|---|---|
| `Application` y módulos | Componer componentes y administrar arranque y cierre. |
| Controller de transporte | Interpretar una interacción y presentar su resultado. |
| UseCase | Coordinar una intención completa mediante colaboradores de aplicación y dominio. |
| Objetos de dominio | Mantener invariantes y decidir según las reglas del negocio. |
| `Invocation` | Construir el ámbito de ejecución y aplicar su política transaccional. |
| `Session`, `IdentityMap`, `UnitOfWork` | Recuperar objetos, preservar identidad y seguir cambios. |
| Descriptores y mappings | Representar la correspondencia entre objetos y almacenamiento. |
| Adaptador de almacenamiento | Ejecutar consultas y modificaciones dentro de una transacción. |
| Registro y traductores de errores | Describir fallos y producir su representación por transporte. |

Los módulos iniciales serán núcleo, aplicación, persistencia, memoria y HTTP. SQLite, gRPC y las capacidades experimentales se incorporarán después.

El arranque validará dependencias, rutas, mappings y registros de errores antes de abrir listeners. Un fallo durante el arranque cerrará los componentes ya iniciados en orden inverso.

### Interfaces principales

- `Controller#call(entrada, contexto:)`: interfaz propia de cada transporte.
- `UseCase#call(**argumentos)`: recibe argumentos de negocio y devuelve un valor; sus colaboradores se inyectan por constructor.
- `Invocation#call(**argumentos)`: crea los colaboradores de esa ejecución, aplica la política transaccional y garantiza la liberación de recursos.
- `Storage#begin_transaction(mode:)`: devuelve una transacción con consultas, altas, modificaciones, bajas, commit y rollback.
- `ErrorRegistry#resolve(exception)`: devuelve una descripción pública del fallo.

Los UseCases serán clases Ruby comunes. El estado de una ejecución permanecerá en variables locales y colaboradores de ese ámbito. Sus resultados usarán objetos de valor, con componentes separados de los objetos administrados por la sesión.

### Recorrido HTTP

El módulo HTTP tendrá listener, parser, router, decodificadores, controllers, presentadores JSON y escritor de respuestas propios.

1. El dispatcher administra conexiones y reconoce los encabezados de una solicitud.
2. La admisión reserva capacidad y crea un Thread nuevo.
3. Ese hilo termina de leer el cuerpo, decodifica la entrada y ejecuta el controller.
4. El controller invoca el UseCase mediante `Invocation`.
5. La ejecución materializa el resultado y confirma la transacción.
6. El presentador y el escritor producen la respuesta.
7. `ensure` libera recursos y devuelve la conexión al dispatcher o la cierra.

Una conexión keep-alive atenderá sus requests secuencialmente, creando un hilo nuevo para cada uno. El dispatcher usará `IO.select` y Fibers; el trabajo de aplicación ocurrirá en el hilo del request.

La admisión tendrá un límite configurable, inicialmente **128 requests activos**. El exceso recibirá 503 antes de crear otro hilo.

### Comportamiento web inicial

- Routing explícito por método y path, con bindings a controllers registrados.
- Parámetros normalizados antes de invocar el UseCase.
- JSON inválido: 400; entrada estructuralmente inválida: 422.
- Rutas inexistentes: 404; método incorrecto: 405 con `Allow`.
- Soporte de HEAD, OPTIONS, keep-alive y cuerpos con longitud o transferencia chunked.
- Rechazo de framing ambiguo, con cierre de conexión.
- Respuestas JSON inicialmente completas en memoria antes de enviarse.
- Límites iniciales configurables: línea de 8 KiB, encabezados totales de 32 KiB y cuerpo JSON de 1 MiB.
- Plazos iniciales: encabezados 10 segundos; cuerpo, ejecución e inactividad 30 segundos.
- TLS mediante `OpenSSL`, configurado con certificados proporcionados por la aplicación.

El parser y el manejo de conexiones seguirán [HTTP/1.1, RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html).

## 3. Estrategia de errores

### Excepciones y traducción

Las excepciones de aplicación y dominio conservarán significado propio. El framework permitirá registrar sus clases sin exigir una superclase del framework.

Cada registro definirá categoría, código público estable, título y extracción explícita de detalles seguros. La resolución elegirá la clase registrada más específica. Los registros duplicados o ambiguos fallarán durante el arranque.

Los traductores de HTTP y gRPC serán objetos distintos que colaboran con ese registro.

| Situación | HTTP | gRPC |
|---|---:|---|
| Entrada inválida | 400 o 422 | `INVALID_ARGUMENT` |
| Identidad ausente | 401 | `UNAUTHENTICATED` |
| Acceso denegado | 403 | `PERMISSION_DENIED` |
| Recurso inexistente | 404 | `NOT_FOUND` |
| Estado de negocio incompatible | 409 | `FAILED_PRECONDITION` |
| Entidad duplicada | 409 | `ALREADY_EXISTS` |
| Conflicto transaccional | 409 | `ABORTED` |
| Capacidad agotada | 429 o 503, según su origen | `RESOURCE_EXHAUSTED` |
| Almacenamiento temporalmente indisponible | 503 | `UNAVAILABLE` |
| Plazo de ejecución agotado | 503 | `DEADLINE_EXCEEDED` |
| Fallo inesperado | 500 | `INTERNAL` |

Los errores propios del transporte tendrán tratamiento específico: por ejemplo, un método RPC desconocido produce `UNIMPLEMENTED`. Los códigos gRPC respetarán sus [semánticas oficiales](https://grpc.io/docs/guides/status-codes/).

### Respuestas públicas y diagnóstico

HTTP usará `application/problem+json`, siguiendo [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457.html), con:

- `type`, `title`, `status` e identificador de la ocurrencia.
- Extensiones `code` y `operation_id`.
- Detalles y violaciones de campos únicamente cuando estén declarados como públicos.

Un fallo inesperado tendrá un mensaje público genérico. Los diagnósticos internos registrarán código, clase, causa, backtrace, duración y estado transaccional, filtrando credenciales, cuerpos y valores SQL.

Cada interacción tendrá un identificador generado por el servidor. Un único `FailureReporter` registrará cada fallo para evitar duplicaciones entre capas.

### Transacciones y fallos tardíos

- Una excepción anterior al commit provoca rollback y descarte del contexto.
- Un fallo durante commit registra si el resultado fue confirmado, revertido o quedó indeterminado.
- Un error de presentación o envío posterior al commit conserva el estado confirmado.
- Si la respuesta ya comenzó, HTTP cierra la conexión. gRPC finalizará el stream con un estado de error cuando todavía sea posible.
- La cancelación se propaga mediante un objeto explícito y comprobaciones cooperativas.
- Una cancelación posterior al commit conserva los efectos confirmados.
- Las escrituras no tendrán reintentos automáticos.
- Si falla el rollback o el cierre, se conserva la excepción principal y se registra el fallo secundario.
- La frontera captura `StandardError`; `ensure` garantiza la limpieza también durante la salida del hilo.

Los fallos del parser, decodificador, controller, UseCase, almacenamiento y escritor utilizarán la misma política de clasificación. Si falla el propio presentador de errores, habrá una respuesta 500 mínima predefinida, siempre que todavía pueda enviarse.

## 4. Implementación por entregas

### Entrega 1: núcleo y ejecución

Implementar módulos, fábricas, ámbitos de ejecución, UseCases, excepciones y observabilidad. Registrar explícitamente una política transaccional por operación: lectura, escritura o ejecución sin almacenamiento.

Usar bloques, módulos y `define_method` para construir las APIs declarativas sobre objetos de descripción. Las clases y los registros se estabilizan al terminar el arranque.

### Entrega 2: Data Mapper y HashMap

Implementar descriptores externos, conversores, consultas como objetos, identidad por sesión y seguimiento de cambios.

El almacenamiento guardará **filas de valores independientes de los objetos de dominio**. Cada transacción tendrá un snapshot y modificaciones privadas. El commit publicará sus cambios atómicamente bajo `Mutex`.

Para la primera versión:

- Identidades UUID generadas mediante `SecureRandom` al registrar altas.
- Lecturas consistentes sobre snapshots.
- Validación conservadora de revisión al confirmar escrituras; una revisión concurrente provoca conflicto.
- Campos simples, objetos de valor y asociaciones explícitas entre entidades.
- Carga de asociaciones mediante planes declarados.
- Resultados públicos materializados antes de cerrar la sesión.
- Consultas compuestas por criterios, orden y paginación, interpretadas por el adaptador.

Esta entrega tendrá almacenamiento en memoria y pérdida de datos al terminar el proceso.

### Entrega 3: HTTP y ejemplo completo

Construir el servidor propio y conectar la política de errores a todas sus etapas.

Crear una aplicación de ejemplo con `ConfirmarPedido`: controller HTTP, UseCase, objetos de dominio y Data Mapper. Demostrar éxito, recurso inexistente, rechazo de negocio, conflicto y fallo inesperado.

### Entrega 4: SQLite

Agregar `sqlite3` como única gem externa y ejecutar la misma suite contractual del almacenamiento.

Implementar sentencias parametrizadas, esquema versionado y traducción por códigos de error del motor. Cada ejecución transaccional tendrá una conexión propia, cerrada al terminar.

Configuración inicial: claves foráneas activas, journal DELETE, sincronización FULL y espera de locks acotada al plazo de ejecución. Usar transacciones IMMEDIATE para escritura y DEFERRED para lectura. [Transacciones SQLite](https://sqlite.org/lang_transaction.html).

### Entrega 5: gRPC propio

Construir HTTP/2, HPACK, framing gRPC y codecs Protocol Buffers usando Ruby y biblioteca estándar.

Primero se implementarán RPC simples; luego streaming del servidor, del cliente y bidireccional. Cada RPC admitida tendrá un hilo nuevo; los mensajes de un stream pertenecerán a esa llamada.

- Descriptores de mensajes como objetos Ruby, con exportación de contratos `.proto`.
- Primera versión del codec: escalares proto3, enums, mensajes anidados y campos repeated.
- Plazos, cancelación, control de flujo y buffers acotados.
- Status gRPC, mensaje público y metadata de código e identificador de operación.
- En streaming, operaciones transaccionales delimitadas por mensaje o lote mediante UseCases; el stream completo no mantendrá una transacción abierta.
- Interoperabilidad comprobada con un cliente independiente.

Las implementaciones seguirán [HTTP/2](https://www.rfc-editor.org/rfc/rfc9113.html), [HPACK](https://www.rfc-editor.org/rfc/rfc7541.html) y el [protocolo gRPC](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md).

### Entrega 6: capacidades opcionales de Ruby

Agregar Ruby Box para aislamiento de definiciones, Ractor para tareas aisladas y comparación de intérprete, YJIT y ZJIT. El hilo del request seguirá siendo dueño de su interacción y sesión.

## 5. Pruebas y entrega del documento

Las pruebas utilizarán Ruby y un ejecutor pequeño propio. Los escenarios cubrirán:

- Dos aplicaciones independientes dentro del mismo proceso.
- UseCases invocados directamente y desde controllers de distintos transportes.
- Hilos distintos para requests sucesivos sobre una misma conexión.
- Aislamiento entre transacciones, rollback sin filtración de cambios y commit atómico.
- Identidad de objetos dentro de una sesión y separación entre sesiones.
- Errores esperados, inesperados, durante commit, presentación, envío y limpieza.
- Solicitudes fragmentadas, framing ambiguo, límites, cancelación y saturación.
- Contratos equivalentes para HashMap y SQLite.
- Interoperabilidad y finalización correcta de streams gRPC.

El comando del ejecutor será `ruby -Ilib:test test/run.rb`, verificando primero Ruby 4.0.8. Cada entrega deberá pasar sus escenarios antes de comenzar la siguiente.

The deliverables are the implemented framework, its passing delivery gates,
executable examples, repository documentation, and the published guides described
below. Implementation, tests, new documentation, and explanatory source comments
use English. Comments explaining protocol constraints and design decisions are
appropriate for this open-source framework.

## 6. Progressive guides and GitHub Pages

### Editorial objective

Create documentation in the repository and publish it as a GitHub Pages site.
Use Rails Guides as an editorial reference: progressive learning, explicit
examples, and substantial explanations of why the framework works as it does.

Each guide must help readers use the framework and understand its design. A
catalog of APIs or short recipes alone does not meet this requirement. All guide
content is original and written in English.

### Learning progression

Organize the index into a recommended learning path, with prerequisites and
links to the preceding and following guides:

1. **Getting started:** install Ruby 4.0.8, run the tests, invoke an ordinary Ruby
   use case directly, and compose the smallest working application.
2. **Objects and responsibilities:** grow the order-confirmation example and
   explain the responsibilities of the domain, use case, repository, controller,
   and invocation boundary.
3. **Composition and execution:** factories, dependency injection, application
   independence, startup validation, resource ownership, and explicit
   transactional policies.
4. **Data Mapper and sessions:** external descriptors, converters, UUIDs,
   identity maps, change tracking, detached results, and rollback semantics.
5. **Queries and associations:** criteria, ordering, pagination, explicit load
   plans, association identity, and the handling of unloaded foreign keys.
6. **HTTP APIs:** build the order endpoint step by step; show parameter
   normalization, JSON, routes, HEAD, OPTIONS, keep-alive, limits, and TLS.
7. **Failures and observability:** register ordinary exceptions, select public
   details, inspect problem responses, and reason about commit, presentation,
   sending, cancellation, and cleanup failures.
8. **SQLite and schema evolution:** replace the memory adapter, evolve a schema,
   explain parameter binding and per-invocation connections, and demonstrate
   DELETE-journal locking and execution deadlines.
9. **gRPC and streaming:** describe messages in Ruby, export `.proto` contracts,
   reuse use cases through another controller, implement each streaming mode,
   and delimit transactions per message or batch.
10. **Concurrency and optional Ruby capabilities:** explain admission, request
    threads, connection and stream flow control, cooperative cancellation,
    Ruby Box, Ractor tasks, and interpreter/YJIT/ZJIT measurements.
11. **Testing and extending the framework:** demonstrate a red-green-refactor
    change, the shared storage contract, independent protocol clients, and the
    protocols required of a new adapter or module.

Readers may enter a focused guide directly; it must state the knowledge and
example state assumed rather than silently depend on earlier steps.

### Requirements for every guide

- State what readers will build or learn and what they need beforehand.
- Introduce one idea at a time, starting with a complete, runnable example.
- Show filenames, commands, inputs, expected outputs, and relevant failures.
- Develop examples through explicit intermediate steps; identify additions and
  changes so that readers can reproduce the progression.
- Explain the reason behind each significant design decision: the problem it
  solves, which object owns the decision, the alternatives considered, and the
  costs or limitations of the selected approach.
- Connect public behavior to the collaboration that produces it. Use diagrams
  when they clarify ownership, transaction boundaries, or message flow.
- Include failure and cleanup behavior alongside successful behavior, with
  examples that distinguish rollback from failures after commit.
- Link to executable example files, relevant tests, related guides, and primary
  protocol references where exact semantics matter.
- End with a concrete next step or exercise that builds on the guide.
- Describe current implementation behavior accurately; identify experimental
  capabilities and limitations explicitly.

### Repository and site

- Keep guide sources, example programs, the site builder, and publishing
  configuration versioned with the framework.
- Provide a clear guide index, topic navigation, an in-page table of contents,
  stable heading links, and previous/next navigation.
- Make long explanations and code comfortable to read on desktop and mobile,
  with semantic HTML, keyboard navigation, visible focus, and sufficient
  contrast.
- Give the site its own restrained presentation. The Rails Guides reference
  governs the teaching depth and progression; it does not require copying
  Rails branding or content.
- Provide documented local build and preview commands, and support the project
  path used by GitHub Pages without broken assets or links.
- Publish through a reproducible GitHub Actions workflow, with tests and guide
  validation as gates before deployment. Keep framework runtime dependencies
  unchanged by the documentation toolchain.

### Verification and publication gate

Documentation is complete when:

1. Every topic in the learning progression has a substantive guide satisfying
   the editorial requirements above.
2. Tutorial examples execute against the current public API, and their asserted
   outputs and failure cases agree with automated checks.
3. The static site builds locally, local links and heading anchors resolve, and
   desktop/mobile rendering and keyboard navigation have been inspected.
4. The full framework suite and documentation checks pass in GitHub Actions.
5. The GitHub Pages deployment succeeds, and the published URL and a guide
   page are fetched to verify the actual deployed content and assets.
6. The repository README links to the published guides and explains how to
   rebuild, preview, and contribute to them.

Publication is part of the requested outcome. An unexecuted workflow, local
preview, or proposed URL alone does not prove that the site is published.

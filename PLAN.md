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

El entregable actual es este plan completo, guardado en `/home/gaston/Code/ruby-object-framework/PLAN.md`. Las entregas de implementación y sus pruebas quedan descritas para el desarrollo posterior.

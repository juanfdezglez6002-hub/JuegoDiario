# LEGENDARIO

El reto diario de videojuegos en el que gana la respuesta más rara.

Cada día salen 5 preguntas de juegos distintos, elegidos al azar. Tienes 30 segundos para cada una. Cualquier respuesta válida suma, pero los puntos dependen del **% de jugadores que dijeron lo mismo que tú**: cuanto menos gente, más puntos (de 0 a 100 por pregunta).

| Nivel | % de jugadores que la dijeron | Puntos aproximados |
|---|---|---|
| ⬜ Común | 15% o más | 0 – 33 |
| 🟦 Raro | del 4% al 15% | 34 – 55 |
| 🟪 Épico | del 1% al 4% | 56 – 79 |
| 🟨 Legendario | menos del 1% | 80 – 100 |

Los puntos son provisionales durante el día y definitivos al día siguiente.

## Cómo está hecho

- `index.html`: toda la web en un solo archivo (HTML, CSS y JavaScript). No contiene las respuestas: las comprueba el servidor.
- `supabase/01_esquema.sql`: base de datos y funciones del servidor (Supabase / PostgreSQL).
  - Las tablas están en un esquema que la API no expone y tienen RLS activado: desde el navegador solo se puede llamar a funciones que validan todo en el servidor.
  - El temporizador lo controla el servidor.
  - Antitrampas: límite de jugadores por conexión y pregunta, freno de peticiones por minuto y votos sin duplicar por conexión. Para ello se usa una huella cifrada de la IP con una clave diaria que se borra a las 48 h; la IP nunca se guarda.

Si `index.html` no tiene configurado el servidor, funciona en **modo demo** con unas preguntas de prueba.

---

Proyecto independiente de fans, sin relación oficial con ninguno de los juegos mencionados. Todas las marcas pertenecen a sus respectivos propietarios.

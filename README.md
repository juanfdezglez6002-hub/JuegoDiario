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

## Jefe del día y liga

- **Jefe del día ⚔️**: cada día un jefe pixel-art distinto (el mismo para todos) con entre 200 y 320 PV. Cada respuesta es un ataque que hace tanto daño como puntos consigues; las épicas son golpes críticos y las legendarias, golpes legendarios. Si tu daño total supera su vida, lo derrotas.
- **Liga 🏆** (se guarda en cada dispositivo): 3 retos de clasificación y empiezas en ⚙️ Hierro. Derrotar al jefe suma una victoria y no derrotarlo resta una. Al llegar a las victorias que pide tu liga, tu siguiente reto es una **partida de ascenso** con el jefe reforzado (+15% de vida para salir de Hierro… hasta +45% para llegar a 👑 Leyenda). Si lo derrotas, asciendes.
- **Sonido 🔊**: golpes distintos según la rareza, voz propia para cada tipo de enemigo y música de victoria, derrota y ascenso. Generado con Web Audio, sin archivos externos.

## Cómo está hecho

- `index.html`: toda la web en un solo archivo (HTML, CSS y JavaScript). No contiene las respuestas: las comprueba el servidor.
- `supabase/01_esquema.sql`: base de datos y funciones del servidor (Supabase / PostgreSQL).
  - Las tablas están en un esquema que la API no expone y tienen RLS activado: desde el navegador solo se puede llamar a funciones que validan todo en el servidor.
  - El temporizador lo controla el servidor.
  - Antitrampas: límite de jugadores por conexión y pregunta, freno de peticiones por minuto y votos sin duplicar por conexión. Para ello se usa una huella cifrada de la IP con una clave diaria que se borra a las 48 h; la IP nunca se guarda.

Si `index.html` no tiene configurado el servidor, funciona en **modo demo** con unas preguntas de prueba.

## Revisar las respuestas que el juego rechaza

Cuando alguien escribe una respuesta que no reconocemos, se guarda el texto (sin relacionarlo con el jugador). Para revisarlo, en el **SQL Editor** de Supabase:

```sql
select * from privado.rechazos_top();      -- lo más escrito y no reconocido, con la respuesta más parecida
select * from privado.rechazos_top(3);     -- solo lo que se repitió 3 veces o más
select * from privado.rechazos_resumen();  -- qué preguntas generan más rechazos
```

Al añadir el alias que faltaba, esa entrada desaparece sola de la lista. Para esconder algo que no es una respuesta válida:

```sql
update privado.rechazos set ignorar = true where clave = 'loquesea';
```

---

Proyecto independiente de fans, sin relación oficial con ninguno de los juegos mencionados. Todas las marcas pertenecen a sus respectivos propietarios.

// Minimal stub SMTP server for Prompt 6 SENT-path testing. No real mail
// ever leaves the machine: accepted messages are appended to a local file.
// Advertises no AUTH extension, so nodemailer skips authentication.
//   STUB_SMTP_PORT (default 4025), STUB_SMTP_OUT (default /tmp/p6-stub-mail.txt)
import net from "node:net";
import { appendFileSync } from "node:fs";

const PORT = Number(process.env.STUB_SMTP_PORT ?? 4025);
const OUT = process.env.STUB_SMTP_OUT ?? "/tmp/p6-stub-mail.txt";

const server = net.createServer((socket) => {
  socket.write("220 stub-smtp ready\r\n");
  let buf = "";
  let inData = false;
  let data = "";
  const handleLine = (line) => {
    if (inData) {
      if (line === ".") {
        inData = false;
        appendFileSync(OUT, data + "\n---END-MESSAGE---\n");
        data = "";
        socket.write("250 OK queued\r\n");
      } else {
        data += line + "\n";
      }
      return;
    }
    const cmd = line.split(" ")[0].toUpperCase();
    if (cmd === "EHLO" || cmd === "HELO") socket.write("250-localhost\r\n250 8BITMIME\r\n");
    else if (cmd === "MAIL" || cmd === "RCPT") socket.write("250 OK\r\n");
    else if (cmd === "DATA") {
      inData = true;
      socket.write("354 End data with <CR><LF>.<CR><LF>\r\n");
    } else if (cmd === "QUIT") {
      socket.write("221 Bye\r\n");
      socket.end();
    } else if (cmd === "RSET" || cmd === "NOOP") socket.write("250 OK\r\n");
    else if (line.trim() !== "") socket.write("250 OK\r\n");
  };
  socket.on("data", (chunk) => {
    buf += chunk.toString();
    let idx;
    while ((idx = buf.indexOf("\r\n")) >= 0) {
      handleLine(buf.slice(0, idx));
      buf = buf.slice(idx + 2);
    }
  });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[stub-smtp] listening on 127.0.0.1:${PORT}, capturing to ${OUT}`);
});

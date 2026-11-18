"""Tangkapan layar aplikasi web di ukuran iPhone. Dipakai oleh workflow e2e."""
import json, os, sys, time
from playwright.sync_api import sync_playwright

BASE = os.environ.get("BASE", "http://localhost:8088")
OUT = sys.argv[1]
TOKEN = open(sys.argv[2]).read().strip()
W, H = 390, 844
os.makedirs(OUT, exist_ok=True)


def settle(page, secs=4):
    page.wait_for_load_state("networkidle")
    time.sleep(secs)


with sync_playwright() as p:
    b = p.chromium.launch()
    logs = []

    def ctx(with_token):
        c = b.new_context(viewport={"width": W, "height": H}, device_scale_factor=2, is_mobile=True, has_touch=True)
        if with_token:
            c.add_init_script(
                "localStorage.setItem('flutter.token', %s);"
                "localStorage.setItem('flutter.device', %s);"
                % (json.dumps(json.dumps(TOKEN)), json.dumps(json.dumps("c0c0c0c0c0c0c0c0c0")))
            )
        pg = c.new_page()
        pg.on("console", lambda m: logs.append(f"{m.type}: {m.text}"))
        pg.on("pageerror", lambda e: logs.append(f"pageerror: {e}"))
        return pg

    pg = ctx(False)
    pg.goto(BASE)
    settle(pg)
    pg.screenshot(path=f"{OUT}/01-pembuka.png")

    pg = ctx(True)
    pg.goto(BASE)
    settle(pg, 6)
    pg.screenshot(path=f"{OUT}/02-timeline.png")

    pg.mouse.click(195, 200)  # thread teratas (milik sendiri, belum dibalas)
    settle(pg)
    pg.screenshot(path=f"{OUT}/03-thread.png")

    pg.goto(BASE)
    settle(pg, 6)
    pg.mouse.click(195, 430)  # thread ketiga: punya balasan + balasan penulis
    settle(pg)
    pg.screenshot(path=f"{OUT}/03b-thread-dibalas.png")

    pg.goto(BASE)
    settle(pg, 6)
    pg.mouse.click(150, 84)  # tab Belum dibalas
    settle(pg, 3)
    pg.screenshot(path=f"{OUT}/04-belum-dibalas.png")
    pg.mouse.click(250, 84)  # tab Ramai
    settle(pg, 3)
    pg.screenshot(path=f"{OUT}/05-ramai.png")

    pg.mouse.click(328, 735)  # tombol Tulis
    settle(pg, 3)
    pg.screenshot(path=f"{OUT}/06-tulis.png")

    pg.goto(BASE)
    settle(pg, 6)
    pg.mouse.click(362, 28)  # pengaturan
    settle(pg, 3)
    pg.screenshot(path=f"{OUT}/07-pengaturan.png")

    open(f"{OUT}/console.txt", "w").write("\n".join(logs))
    b.close()
print("ok")

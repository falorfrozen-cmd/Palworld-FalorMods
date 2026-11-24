-- BaseWorkerMultiplier ayarlari
-- Degisiklikten sonra oyunu yeniden baslat.

return {
    -- Her us seviyesindeki calisan Pal limitini bu sayi ile carpar.
    -- 3 = 3 kat, 4 = 4 kat vb. Ondalik da olur (2.5 gibi).
    Multiplier = 3,

    -- Dunya ayarindaki "Ustaki maksimum calisan Pal" ust sinirini de
    -- otomatik yukseltir (yoksa oyun limiti yine bu ayarda keser).
    -- Sadece YUKSELTIR, hicbir zaman dusurmez.
    RaiseWorldCap = true,

    -- Guvenlik icin mutlak ust sinir (performans icin cok yuksek tutma).
    HardMax = 150,

    -- UE4SS.log icine ayrintili bilgi yaz.
    Debug = true,
}

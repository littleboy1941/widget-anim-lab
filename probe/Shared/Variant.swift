// Что показывает первый виджет («Probe 0»), который UI-тест ставит на домашний экран.
// CI перезаписывает этот файл для каждого задания матрицы (font-probe.yml).
// Текущая матрица: fps8, fps12, fps16, fps24, fps30, fps24o0, fps30o0,
// fontA24, fontA30, fontA8svg. CI собирает их с RATE_EXPERIMENTS.
// Прежние len160s, len80c20, split160, grp80, grp160 доступны с LENGTH_EXPERIMENTS.
// Старые режимы overlap, lenN, memN и diag остаются доступны.
enum Variant {
    static let mode = "overlap"
}

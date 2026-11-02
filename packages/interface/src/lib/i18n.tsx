import { createContext, useContext, type ReactNode } from "react";

export type ResolvedLanguage = "zh" | "en";

const LanguageContext = createContext<ResolvedLanguage>("zh");

export function LanguageProvider({
  language,
  children,
}: {
  language: ResolvedLanguage;
  children: ReactNode;
}) {
  return (
    <LanguageContext.Provider value={language}>
      {children}
    </LanguageContext.Provider>
  );
}

export function useLanguage(): ResolvedLanguage {
  return useContext(LanguageContext);
}

export function useTranslation() {
  const language = useLanguage();
  return (english: string, chinese: string) =>
    language === "zh" ? chinese : english;
}

export function localized(
  english: string,
  chinese: string,
  language: ResolvedLanguage,
): string {
  return language === "zh" ? chinese : english;
}

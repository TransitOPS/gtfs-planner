defmodule GtfsPlanner.Gtfs.LanguageCodes do
  @moduledoc """
  Language codes for the feed-info and agency language selects (R12).

  Select options are labelled `"English (en)"`. The feed language adds `mul`
  through `include_mul: true`; agency and default languages do not. A stored
  code outside the list stays selectable under "Current value" instead of being
  silently replaced (R12).
  """

  @common ~w(en es fr de pt zh ar ru ja ko it vi)

  @languages [
    {"aa", "Afar"},
    {"ab", "Abkhazian"},
    {"ae", "Avestan"},
    {"af", "Afrikaans"},
    {"ak", "Akan"},
    {"am", "Amharic"},
    {"an", "Aragonese"},
    {"ar", "Arabic"},
    {"as", "Assamese"},
    {"av", "Avaric"},
    {"ay", "Aymara"},
    {"az", "Azerbaijani"},
    {"ba", "Bashkir"},
    {"be", "Belarusian"},
    {"bg", "Bulgarian"},
    {"bi", "Bislama"},
    {"bm", "Bambara"},
    {"bn", "Bengali"},
    {"bo", "Tibetan"},
    {"br", "Breton"},
    {"bs", "Bosnian"},
    {"ca", "Catalan"},
    {"ce", "Chechen"},
    {"ch", "Chamorro"},
    {"co", "Corsican"},
    {"cr", "Cree"},
    {"cs", "Czech"},
    {"cu", "Church Slavic"},
    {"cv", "Chuvash"},
    {"cy", "Welsh"},
    {"da", "Danish"},
    {"de", "German"},
    {"dv", "Divehi"},
    {"dz", "Dzongkha"},
    {"ee", "Ewe"},
    {"el", "Greek"},
    {"en", "English"},
    {"eo", "Esperanto"},
    {"es", "Spanish"},
    {"et", "Estonian"},
    {"eu", "Basque"},
    {"fa", "Persian"},
    {"ff", "Fula"},
    {"fi", "Finnish"},
    {"fj", "Fijian"},
    {"fo", "Faroese"},
    {"fr", "French"},
    {"fy", "Western Frisian"},
    {"ga", "Irish"},
    {"gd", "Scottish Gaelic"},
    {"gl", "Galician"},
    {"gn", "Guarani"},
    {"gu", "Gujarati"},
    {"gv", "Manx"},
    {"ha", "Hausa"},
    {"he", "Hebrew"},
    {"hi", "Hindi"},
    {"ho", "Hiri Motu"},
    {"hr", "Croatian"},
    {"ht", "Haitian Creole"},
    {"hu", "Hungarian"},
    {"hy", "Armenian"},
    {"hz", "Herero"},
    {"ia", "Interlingua"},
    {"id", "Indonesian"},
    {"ie", "Interlingue"},
    {"ig", "Igbo"},
    {"ii", "Sichuan Yi"},
    {"ik", "Inupiaq"},
    {"io", "Ido"},
    {"is", "Icelandic"},
    {"it", "Italian"},
    {"iu", "Inuktitut"},
    {"ja", "Japanese"},
    {"jv", "Javanese"},
    {"ka", "Georgian"},
    {"kg", "Kongo"},
    {"ki", "Kikuyu"},
    {"kj", "Kuanyama"},
    {"kk", "Kazakh"},
    {"kl", "Kalaallisut"},
    {"km", "Khmer"},
    {"kn", "Kannada"},
    {"ko", "Korean"},
    {"kr", "Kanuri"},
    {"ks", "Kashmiri"},
    {"ku", "Kurdish"},
    {"kv", "Komi"},
    {"kw", "Cornish"},
    {"ky", "Kyrgyz"},
    {"la", "Latin"},
    {"lb", "Luxembourgish"},
    {"lg", "Ganda"},
    {"li", "Limburgish"},
    {"ln", "Lingala"},
    {"lo", "Lao"},
    {"lt", "Lithuanian"},
    {"lu", "Luba-Katanga"},
    {"lv", "Latvian"},
    {"mg", "Malagasy"},
    {"mh", "Marshallese"},
    {"mi", "Māori"},
    {"mk", "Macedonian"},
    {"ml", "Malayalam"},
    {"mn", "Mongolian"},
    {"mr", "Marathi"},
    {"ms", "Malay"},
    {"mt", "Maltese"},
    {"my", "Burmese"},
    {"na", "Nauru"},
    {"nb", "Norwegian Bokmål"},
    {"nd", "North Ndebele"},
    {"ne", "Nepali"},
    {"ng", "Ndonga"},
    {"nl", "Dutch"},
    {"nn", "Norwegian Nynorsk"},
    {"no", "Norwegian"},
    {"nr", "South Ndebele"},
    {"nv", "Navajo"},
    {"ny", "Nyanja"},
    {"oc", "Occitan"},
    {"oj", "Ojibwa"},
    {"om", "Oromo"},
    {"or", "Odia"},
    {"os", "Ossetic"},
    {"pa", "Punjabi"},
    {"pi", "Pali"},
    {"pl", "Polish"},
    {"ps", "Pashto"},
    {"pt", "Portuguese"},
    {"qu", "Quechua"},
    {"rm", "Romansh"},
    {"rn", "Rundi"},
    {"ro", "Romanian"},
    {"ru", "Russian"},
    {"rw", "Kinyarwanda"},
    {"sa", "Sanskrit"},
    {"sc", "Sardinian"},
    {"sd", "Sindhi"},
    {"se", "Northern Sami"},
    {"sg", "Sango"},
    {"sh", "Serbo-Croatian"},
    {"si", "Sinhala"},
    {"sk", "Slovak"},
    {"sl", "Slovenian"},
    {"sm", "Samoan"},
    {"sn", "Shona"},
    {"so", "Somali"},
    {"sq", "Albanian"},
    {"sr", "Serbian"},
    {"ss", "Swati"},
    {"st", "Southern Sotho"},
    {"su", "Sundanese"},
    {"sv", "Swedish"},
    {"sw", "Swahili"},
    {"ta", "Tamil"},
    {"te", "Telugu"},
    {"tg", "Tajik"},
    {"th", "Thai"},
    {"ti", "Tigrinya"},
    {"tk", "Turkmen"},
    {"tl", "Tagalog"},
    {"tn", "Tswana"},
    {"to", "Tongan"},
    {"tr", "Turkish"},
    {"ts", "Tsonga"},
    {"tt", "Tatar"},
    {"tw", "Twi"},
    {"ty", "Tahitian"},
    {"ug", "Uyghur"},
    {"uk", "Ukrainian"},
    {"ur", "Urdu"},
    {"uz", "Uzbek"},
    {"ve", "Venda"},
    {"vi", "Vietnamese"},
    {"vo", "Volapük"},
    {"wa", "Walloon"},
    {"wo", "Wolof"},
    {"xh", "Xhosa"},
    {"yi", "Yiddish"},
    {"yo", "Yoruba"},
    {"za", "Zhuang"},
    {"zh", "Chinese"},
    {"zu", "Zulu"}
  ]

  @names Map.new(@languages)
  @codes Enum.map(@languages, &elem(&1, 0))

  @spec valid?(String.t() | nil, keyword()) :: boolean()
  def valid?(code, opts) do
    is_binary(code) and
      (code in @codes or (code == "mul" and Keyword.get(opts, :include_mul, false)))
  end

  @spec options(keyword()) :: [{String.t(), [{String.t(), String.t()}]}]
  def options(opts) do
    include_mul? = Keyword.get(opts, :include_mul, false)

    current_group(include_mul?, Keyword.get(opts, :current)) ++
      [common_group(include_mul?), all_languages_group()]
  end

  defp current_group(include_mul?, current) do
    if keep_current?(include_mul?, current) do
      [{"Current value", [{current, current}]}]
    else
      []
    end
  end

  defp keep_current?(include_mul?, current) do
    is_binary(current) and String.trim(current) != "" and
      not valid?(current, include_mul: include_mul?)
  end

  defp common_group(include_mul?) do
    entries = Enum.map(@common, &labelled/1)

    entries =
      if include_mul? do
        entries ++ [{"Multilingual (mul)", "mul"}]
      else
        entries
      end

    {"Common", entries}
  end

  defp all_languages_group do
    entries =
      @languages
      |> Enum.map(&labelled/1)
      |> Enum.sort_by(&elem(&1, 0))

    {"All languages", entries}
  end

  defp labelled({code, name}), do: {"#{name} (#{code})", code}
  defp labelled(code) when is_binary(code), do: labelled({code, Map.fetch!(@names, code)})
end

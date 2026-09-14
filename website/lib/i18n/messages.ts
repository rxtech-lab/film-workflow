import { DEFAULT_LOCALE, type Locale } from "./locale";

/**
 * Every string the server writes for a person to read and does not store in
 * the database: taxonomy defaults, the authoring form's own labels, the sign-in
 * form the app renders, and the error messages the app shows when a request is
 * refused.
 *
 * `en` is the source. A translation that is missing — a key added here and not
 * yet translated below — falls back to the English text rather than printing a
 * key, which is why `zhHans` is typed against `en` but its values are checked
 * only for type, never for presence.
 *
 * Text stored in the database (item titles, category names) is not here; that
 * is per-row and lives in each table's `translations` column.
 */
const en = {
  // MARK: - Errors
  "error.unauthorized": "Authentication is required",
  "error.forbidden": "This action requires the admin role",
  "error.insufficientCredits": "You do not have enough points for this operation.",
  "error.invalidRequest": "The request was rejected.",
  "error.marketplace.notFound": "Marketplace item not found.",
  "error.marketplace.notPurchased": "Buy this item before downloading it.",
  "error.marketplace.noContent": "This item has no downloadable file yet.",
  "error.marketplace.billingUnavailable": "The purchase could not be completed.",
  "error.marketplace.storageUnavailable": "Downloads are not available right now.",
  "error.marketplace.requestFailed": "The request could not be completed.",
  "error.ai.modelNotAllowed": "This model is not available for the selected capability.",
  "error.ai.priceNotFound": "Pricing is not configured for this model.",
  "error.ai.providerResponseInvalid": "The provider returned an unreadable response.",
  "error.ai.requestFailed": "The AI request could not be completed.",

  // MARK: - What the authoring form says when it refuses a change
  "authoring.invalid": "The change could not be saved.",
  "authoring.invalidCategory": "Invalid category.",
  "authoring.invalidItem": "Invalid item.",
  "authoring.invalidKind": "Invalid kind.",
  "authoring.invalidUpload": "Invalid upload.",
  "authoring.uploadTooLarge": "That file is too large for its slot.",
  "authoring.itemHasPurchases": "Someone has bought this item; unpublish it instead of deleting it.",
  "authoring.categoryExists": "A category with that slug already exists for this kind.",
  "authoring.categoryMissing": "This category no longer exists.",
  "authoring.categoryHasItems": "This category still contains items, including drafts. Move them to another category before deleting it.",
  "authoring.categoryMismatch": "Pick a category that belongs to this kind.",
  "authoring.itemMissing": "This item no longer exists.",
  "authoring.storageUnconfigured": "Object storage is not configured.",
  "authoring.descriptorRejected": "Descriptor rejected: {reason}",
  "authoring.kindLocked": "Remove the content file before changing the kind.",
  "authoring.contentRequired": "Upload the content file before publishing.",
  "authoring.remotionPreviewRequired": "Remotion compositions need a preview still before publishing.",
  "authoring.mediaTypeMissing": "Re-upload the content file so its media type can be recorded.",
  "authoring.templateAssetsRequired": "Templates need a cover and a preview made with mock images.",
  "authoring.dependencyUnavailable": "Marketplace dependency {id} is unavailable. Choose a published asset.",
  "authoring.shotSourceRequired": "{shot} needs a media or Remotion source.",
  "authoring.shotModifierUnlisted": "{shot} uses an unlisted effect or transition. Add its marketplace dependency or choose a built-in modifier.",
  "authoring.extensionNotAllowed": "A {slot} for this kind must be one of: {extensions}.",
  "authoring.objectNotThisItem": "That object does not belong to this item.",
  "authoring.uploadMetadataMissing": "Storage did not retain this upload's authorization metadata. Retry the file upload.",
  "authoring.uploadNotAuthorized": "This upload was not authorized for your account and this slot. Retry the file upload from the current account.",
  "authoring.descriptorKindMismatch": "This descriptor is a {descriptor}, but the item is a {kind}.",
  "authoring.descriptorOnlyKinds": "Only effects and transitions have descriptors.",
  "authoring.contentNotText": "This item needs a media or font file.",
  "authoring.contentEmpty": "Content cannot be empty.",
  "authoring.contentTooLarge": "Content is too large.",

  // MARK: - Kinds, as the sidebar lists them
  "kind.footage.label": "Footage",
  "kind.remotion.label": "Remotion Compositions",
  "kind.audio.label": "Music",
  "kind.sound_effect.label": "Sound Effects",
  "kind.font.label": "Fonts",
  "kind.transition.label": "Transitions",
  "kind.effect.label": "Effects",
  "kind.project_template.label": "Project Templates",

  // MARK: - Kinds, as one item names itself in the form
  "kind.footage.name": "Footage",
  "kind.remotion.name": "Remotion composition",
  "kind.audio.name": "Music",
  "kind.sound_effect.name": "Sound effect",
  "kind.font.name": "Font",
  "kind.transition.name": "Transition",
  "kind.effect.name": "Effect",
  "kind.project_template.name": "Project template",

  // MARK: - Footage's sub-shelf
  "mediaType.image.label": "Images",
  "mediaType.video.label": "Video",

  // MARK: - The authoring form
  "form.section.details": "Details",
  "form.section.translations": "Translations",
  "form.section.translations.help": "Optional. Clients asking for this language are sent these instead; anything left blank falls back to the text above.",
  "form.field.kind": "Item type",
  "form.field.category": "Category",
  "form.field.title": "Title",
  "form.field.description": "Description",
  "form.field.description.help": "One or two lines for the card and the detail sheet.",
  "form.field.price": "Price",
  "form.field.price.help": "Credits · 0 is free.",
  "form.field.tags": "Tags",
  "form.field.tags.help": "Separated by commas.",
  "form.field.fontFamily": "Font family",
  "form.field.fontFamily.placeholder": "Exactly as the font reports it, e.g. Inter",
  "form.content.project_template.title": "Template",
  "form.content.project_template.hint": "The shot plan, prompts and references the app fills in when someone starts a film from this.",
  "form.content.footage.title": "Footage file",
  "form.content.footage.hint": "MP4 or MOV, or a PNG, JPEG or WebP still. Dimensions — and a clip's duration — are read from the file, and decide whether it shelves under Images or Video.",
  "form.content.remotion.title": "Composition archive",
  "form.content.remotion.hint": "A zip of the Remotion project: src/, public/, the config files and rxremotion.json. The app builds it for you from a composition in a film.",
  "form.content.audio.title": "Music file",
  "form.content.audio.hint": "MP3, WAV, M4A or AAC. Duration is read from the file.",
  "form.content.sound_effect.title": "Sound file",
  "form.content.sound_effect.hint": "MP3, WAV, M4A or AAC. Duration is read from the file.",
  "form.content.font.title": "Font file",
  "form.content.font.hint": "TTF or OTF.",
  "form.content.transition.title": "Transition definition",
  "form.content.transition.hint": "A Core Image filter and the controls the inspector shows for it.",
  "form.content.effect.title": "Effect definition",
  "form.content.effect.hint": "A Core Image filter and the controls the inspector shows for it.",
  "form.previewImage.title": "Preview image",
  "form.previewImage.project_template.hint": "Cover art for this template.",
  "form.previewImage.footage.hint": "The still on the card. Aim for a frame from the clip, or the image itself.",
  "form.previewImage.remotion.hint": "Frame 0 of the composition, rendered natively.",
  "form.previewImage.audio.hint": "Cover art for the card.",
  "form.previewImage.sound_effect.hint": "Cover art for the card.",
  "form.previewImage.font.hint": "A specimen: the alphabet or a sample line set in the font.",
  "form.previewImage.transition.hint": "A frame mid-transition.",
  "form.previewImage.effect.hint": "A frame with the effect applied.",
  "form.previewVideo.title": "Preview video",
  "form.previewAudio.title": "Audio preview",
  "form.previewAudio.hint": "Upload an audio excerpt or a preview video for listeners to play before installing.",
  "form.previewVideo.hint.template": "Required for publication. A short video made using mock images.",
  "form.previewVideo.hint.default": "Optional. A short demonstration, up to 15 seconds, with sound.",

  // MARK: - The sign-in form the app draws from `api/auth/ui-schema`
  "auth.signIn.title": "Sign In",
  "auth.signUp.title": "Create Account",
  "auth.field.email": "Email",
  "auth.field.email.placeholder": "you@example.com",
  "auth.field.name": "Name",
  "auth.field.name.placeholder": "Your name",
  "auth.field.password": "Password",
} as const;

export type MessageKey = keyof typeof en;

const zhHans: Partial<Record<MessageKey, string>> = {
  "error.unauthorized": "需要先登录。",
  "error.forbidden": "该操作需要管理员权限。",
  "error.insufficientCredits": "积分不足，无法完成此操作。",
  "error.invalidRequest": "请求已被拒绝。",
  "error.marketplace.notFound": "找不到该市场项目。",
  "error.marketplace.notPurchased": "请先购买该项目，然后再下载。",
  "error.marketplace.noContent": "该项目还没有可下载的文件。",
  "error.marketplace.billingUnavailable": "购买未能完成。",
  "error.marketplace.storageUnavailable": "下载暂时不可用。",
  "error.marketplace.requestFailed": "请求未能完成。",
  "error.ai.modelNotAllowed": "所选功能不支持该模型。",
  "error.ai.priceNotFound": "该模型尚未配置价格。",
  "error.ai.providerResponseInvalid": "服务商返回了无法解析的响应。",
  "error.ai.requestFailed": "AI 请求未能完成。",

  "authoring.invalid": "该修改未能保存。",
  "authoring.invalidCategory": "分类无效。",
  "authoring.invalidItem": "项目无效。",
  "authoring.invalidKind": "类型无效。",
  "authoring.invalidUpload": "上传无效。",
  "authoring.uploadTooLarge": "该文件超出了这个位置允许的大小。",
  "authoring.itemHasPurchases": "已经有人购买了这个项目；请将其下架，而不是删除。",
  "authoring.categoryExists": "该类型下已存在使用这个 slug 的分类。",
  "authoring.categoryMissing": "该分类已不存在。",
  "authoring.categoryHasItems": "该分类下仍有项目（包括草稿）。请先把它们移到其他分类，再删除。",
  "authoring.categoryMismatch": "请选择属于该类型的分类。",
  "authoring.itemMissing": "该项目已不存在。",
  "authoring.storageUnconfigured": "对象存储尚未配置。",
  "authoring.descriptorRejected": "描述文件被拒绝：{reason}",
  "authoring.kindLocked": "更改类型前，请先移除内容文件。",
  "authoring.contentRequired": "发布前请先上传内容文件。",
  "authoring.remotionPreviewRequired": "Remotion 合成需要先有预览静帧才能发布。",
  "authoring.mediaTypeMissing": "请重新上传内容文件，以便记录它的媒体类型。",
  "authoring.templateAssetsRequired": "模板需要封面图，以及一段用占位图制作的预览视频。",
  "authoring.dependencyUnavailable": "市场依赖 {id} 不可用。请选择一个已发布的资源。",
  "authoring.shotSourceRequired": "{shot} 需要一个媒体或 Remotion 来源。",
  "authoring.shotModifierUnlisted": "{shot} 使用了未列出的特效或转场。请添加对应的市场依赖，或改用内置修饰器。",
  "authoring.extensionNotAllowed": "该类型的{slot}必须是以下之一：{extensions}。",
  "authoring.objectNotThisItem": "该对象不属于这个项目。",
  "authoring.uploadMetadataMissing": "存储没有保留这次上传的授权信息。请重新上传文件。",
  "authoring.uploadNotAuthorized": "这次上传未获得当前账户与该位置的授权。请用当前账户重新上传。",
  "authoring.descriptorKindMismatch": "这个描述文件是{descriptor}，但项目是{kind}。",
  "authoring.descriptorOnlyKinds": "只有特效和转场才有描述文件。",
  "authoring.contentNotText": "该项目需要一个媒体或字体文件。",
  "authoring.contentEmpty": "内容不能为空。",
  "authoring.contentTooLarge": "内容过大。",

  "kind.footage.label": "素材",
  "kind.remotion.label": "Remotion 合成",
  "kind.audio.label": "音乐",
  "kind.sound_effect.label": "音效",
  "kind.font.label": "字体",
  "kind.transition.label": "转场",
  "kind.effect.label": "特效",
  "kind.project_template.label": "项目模板",

  "kind.footage.name": "素材",
  "kind.remotion.name": "Remotion 合成",
  "kind.audio.name": "音乐",
  "kind.sound_effect.name": "音效",
  "kind.font.name": "字体",
  "kind.transition.name": "转场",
  "kind.effect.name": "特效",
  "kind.project_template.name": "项目模板",

  "mediaType.image.label": "图片",
  "mediaType.video.label": "视频",

  "form.section.details": "详情",
  "form.section.translations": "翻译",
  "form.section.translations.help": "可选。请求该语言的客户端会收到这里的内容；留空的字段会回退到上面的原文。",
  "form.field.kind": "项目类型",
  "form.field.category": "分类",
  "form.field.title": "标题",
  "form.field.description": "描述",
  "form.field.description.help": "一两句话，显示在卡片和详情页上。",
  "form.field.price": "价格",
  "form.field.price.help": "积分 · 0 表示免费。",
  "form.field.tags": "标签",
  "form.field.tags.help": "用逗号分隔。",
  "form.field.fontFamily": "字体家族",
  "form.field.fontFamily.placeholder": "与字体自身报告的名称完全一致，例如 Inter",
  "form.content.project_template.title": "模板",
  "form.content.project_template.hint": "从这个模板开始创作时，应用会填入的分镜计划、提示词和参考素材。",
  "form.content.footage.title": "素材文件",
  "form.content.footage.hint": "MP4 或 MOV，也可以是 PNG、JPEG 或 WebP 静帧。尺寸（以及视频的时长）会从文件中读取，并决定它归入「图片」还是「视频」。",
  "form.content.remotion.title": "合成归档",
  "form.content.remotion.hint": "Remotion 项目的 zip 包：src/、public/、各配置文件以及 rxremotion.json。应用可以直接用影片中的合成为你打包。",
  "form.content.audio.title": "音乐文件",
  "form.content.audio.hint": "MP3、WAV、M4A 或 AAC。时长会从文件中读取。",
  "form.content.sound_effect.title": "音效文件",
  "form.content.sound_effect.hint": "MP3、WAV、M4A 或 AAC。时长会从文件中读取。",
  "form.content.font.title": "字体文件",
  "form.content.font.hint": "TTF 或 OTF。",
  "form.content.transition.title": "转场定义",
  "form.content.transition.hint": "一个 Core Image 滤镜，以及检查器为它显示的控件。",
  "form.content.effect.title": "特效定义",
  "form.content.effect.hint": "一个 Core Image 滤镜，以及检查器为它显示的控件。",
  "form.previewImage.title": "预览图",
  "form.previewImage.project_template.hint": "这个模板的封面图。",
  "form.previewImage.footage.hint": "卡片上的静帧。最好取自片段中的某一帧，或者就用图片本身。",
  "form.previewImage.remotion.hint": "合成的第 0 帧，原生渲染。",
  "form.previewImage.audio.hint": "卡片的封面图。",
  "form.previewImage.sound_effect.hint": "卡片的封面图。",
  "form.previewImage.font.hint": "字样示例：字母表，或用该字体排的一行示例文字。",
  "form.previewImage.transition.hint": "转场进行中的一帧。",
  "form.previewImage.effect.hint": "应用特效后的一帧。",
  "form.previewVideo.title": "预览视频",
  "form.previewAudio.title": "音频预览",
  "form.previewAudio.hint": "上传音频片段或预览视频，供用户在安装前试听。",
  "form.previewVideo.hint.template": "发布前必填。使用占位图制作的短视频。",
  "form.previewVideo.hint.default": "可选。一段不超过 15 秒的演示，可以带声音。",

  "auth.signIn.title": "登录",
  "auth.signUp.title": "创建账户",
  "auth.field.email": "邮箱",
  "auth.field.email.placeholder": "you@example.com",
  "auth.field.name": "姓名",
  "auth.field.name.placeholder": "你的姓名",
  "auth.field.password": "密码",
};

const catalog: Record<Locale, Partial<Record<MessageKey, string>>> = { en, "zh-Hans": zhHans };

/**
 * One string in `locale`, falling back to the English source when untranslated.
 * `params` fill the `{name}` placeholders a few messages carry; a placeholder
 * with no value is left as written rather than printed as "undefined".
 */
export function t(locale: Locale, key: MessageKey, params?: Record<string, string | number>): string {
  const text = catalog[locale]?.[key] ?? catalog[DEFAULT_LOCALE][key] ?? en[key];
  if (!params) return text;
  return text.replace(/\{(\w+)\}/g, (placeholder, name: string) => (name in params ? String(params[name]) : placeholder));
}

/**
 * How a translated field is titled in the admin form: the field's own title
 * plus the language it holds, e.g. "Title · 简体中文".
 */
export function translatedFieldTitle(locale: Locale, key: MessageKey, languageName: string) {
  return `${t(locale, key)} · ${languageName}`;
}

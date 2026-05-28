/**
 * Chinese name detection.
 * Fixes: O(n*m) name tagging replaced with trie in html.ts.
 * Uses Map instead of StringHashMap.
 */

import { isCjkChar, codePointAt } from './cjk.js';

const SURNAMES: string[] = [
  '艾', '爱', '安', '敖', '巴', '白', '柏', '班', '包', '薄', '鲍', '暴', '贝', '边', '卞',
  '蔡', '曹', '曾', '查', '柴', '昌', '巢', '车', '陈', '成', '程', '池', '迟', '充', '仇',
  '楚', '褚', '崔', '戴', '单', '淡', '澹台', '党', '德', '邓', '狄', '翟', '刁', '丁',
  '东方', '东郭', '董', '都', '豆', '窦', '独孤', '杜', '段', '樊', '范', '方', '房', '费',
  '封', '冯', '伏', '付', '傅', '富', '甘', '干', '高', '戈', '葛', '耿', '弓', '公', '公孙',
  '公冶', '宫', '龚', '巩', '贡', '勾', '苟', '古', '顾', '关', '官', '管', '龟', '桂', '郭',
  '国', '海', '韩', '杭', '郝', '何', '贺', '红', '洪', '侯', '后', '胡', '扈', '花', '华',
  '怀', '皇甫', '霍', '姬', '吉', '纪', '贾', '简', '江', '姜', '蒋', '焦', '竭', '解', '金',
  '晋', '经', '荆', '景', '康', '空', '孔', '寇', '匡', '来', '赖', '蓝', '郎', '雷', '冷',
  '黎', '李', '里', '理', '厉', '利', '荔', '连', '练', '良', '梁', '林', '蔺', '凌', '令狐',
  '刘', '柳', '龙', '娄', '楼', '卢', '鲁', '陆', '闾', '吕', '栾', '罗', '骆', '马', '满',
  '芒', '毛', '茅', '梅', '门', '孟', '米', '苗', '明', '莫', '牟', '缪', '慕容', '穆', '那',
  '年', '聂', '宁', '牛', '诺', '欧', '欧阳', '潘', '庞', '裴', '彭', '皮', '平', '蒲', '濮阳',
  '浦', '漆', '祁', '齐', '钱', '强', '秦', '琴', '青', '丘', '邱', '裘', '屈', '全', '权',
  '冉', '饶', '任', '荣', '容', '阮', '瑞', '桑', '沙', '山', '商', '上官', '尚', '邵', '申',
  '申屠', '沈', '盛', '施', '石', '史', '手', '寿', '舒', '帅', '舜', '司', '司空', '司寇',
  '司马', '司徒', '松', '宋', '苏', '隋', '孙', '太叔', '汤', '唐', '陶', '田', '铁', '佟',
  '童', '涂', '屠', '土', '托', '万', '万俟', '汪', '王', '危', '微', '卫', '尉迟', '魏',
  '温', '文', '闻', '闻人', '翁', '吴', '伍', '武', '昔', '夏', '鲜', '鲜于', '显', '向',
  '项', '萧', '辛', '邢', '熊', '胥', '徐', '许', '轩辕', '宣', '薛', '闫', '严', '言', '阎',
  '颜', '晏', '燕', '阳', '杨', '姚', '叶', '宜', '易', '益', '殷', '尹', '尤', '游', '于',
  '余', '虞', '宇文', '郁', '喻', '元', '原', '袁', '岳', '昝', '展', '张', '章', '长孙',
  '兆', '赵', '郑', '志', '钟', '钟离', '仲孙', '周', '朱', '诸', '诸葛', '祝', '梓', '子',
  '宗', '宗政', '邹', '祖', '左',
];

function findLongestSurname(text: string): number {
  let surnameLen = 0;
  for (const surname of SURNAMES) {
    if (text.startsWith(surname)) {
      if (surname.length > surnameLen) surnameLen = surname.length;
    }
  }
  return surnameLen;
}

function isCjkCharAt(text: string, index: number): boolean {
  const decoded = codePointAt(text, index);
  if (!decoded) return false;
  return isCjkChar(decoded.cp);
}

function tryMatchChineseNameLoose(text: string, start: number): number | null {
  const surnameLen = findLongestSurname(text.substring(start));
  if (surnameLen === 0) return null;

  // Must not be preceded by a CJK character
  if (start > 0) {
    let prev = start - 1;
    while (prev > 0 && (text.charCodeAt(prev) & 0xc0) === 0x80) prev--;
    if (isCjkCharAt(text, prev)) return null;
  }

  let pos = start + surnameLen;
  let givenNameChars = 0;

  while (givenNameChars < 3) {
    const decoded = codePointAt(text, pos);
    if (!decoded || !isCjkChar(decoded.cp)) break;
    pos += decoded.len;
    givenNameChars++;
  }

  if (givenNameChars === 0) return null;
  return pos - start;
}

function countCjkChars(html: string, charFreq: Map<string, number>): void {
  let i = 0;
  while (i < html.length) {
    if (html[i] === '<') {
      const tagEnd = html.indexOf('>', i);
      if (tagEnd === -1) {
        i++;
        continue;
      }
      i = tagEnd + 1;
    } else {
      const textEnd = html.indexOf('<', i);
      const text = textEnd === -1 ? html.substring(i) : html.substring(i, textEnd);

      let j = 0;
      while (j < text.length) {
        const decoded = codePointAt(text, j);
        if (!decoded) {
          j++;
          continue;
        }
        if (isCjkChar(decoded.cp)) {
          const ch = text.substring(j, j + decoded.len);
          charFreq.set(ch, (charFreq.get(ch) || 0) + 1);
        }
        j += decoded.len;
      }

      i = textEnd === -1 ? html.length : textEnd;
    }
  }
}

function collectCandidates(html: string, candidates: Map<string, number>): void {
  let i = 0;
  while (i < html.length) {
    if (html[i] === '<') {
      const tagEnd = html.indexOf('>', i);
      if (tagEnd === -1) {
        i++;
        continue;
      }
      i = tagEnd + 1;
    } else {
      const textEnd = html.indexOf('<', i);
      const text = textEnd === -1 ? html.substring(i) : html.substring(i, textEnd);

      let j = 0;
      while (j < text.length) {
        const surnameLen = findLongestSurname(text.substring(j));
        if (surnameLen === 0) {
          j++;
          continue;
        }

        // Must not be preceded by a CJK character
        if (j > 0) {
          let prev = j - 1;
          while (prev > 0 && (text.charCodeAt(prev) & 0xc0) === 0x80) prev--;
          if (isCjkCharAt(text, prev)) {
            j++;
            continue;
          }
        }

        let pos = j + surnameLen;
        let givenNameChars = 0;

        while (givenNameChars < 3) {
          const decoded = codePointAt(text, pos);
          if (!decoded || !isCjkChar(decoded.cp)) break;
          pos += decoded.len;
          givenNameChars++;

          const name = text.substring(j, pos);
          candidates.set(name, (candidates.get(name) || 0) + 1);
        }

        j = pos;
      }

      i = textEnd === -1 ? html.length : textEnd;
    }
  }
}

function minCharFreq(name: string, charFreq: Map<string, number>): number | null {
  let minFreq = Infinity;
  let charsSeen = 0;
  let k = 0;
  while (k < name.length) {
    const decoded = codePointAt(name, k);
    if (!decoded) break;
    const ch = name.substring(k, k + decoded.len);
    const freq = charFreq.get(ch) || 0;
    if (freq < minFreq) minFreq = freq;
    k += decoded.len;
    charsSeen++;
  }
  if (charsSeen === 0 || minFreq === 0 || minFreq === Infinity) return null;
  return minFreq;
}

function addFilteredNames(
  candidates: Map<string, number>,
  charFreq: Map<string, number>,
  result: Map<string, number>
): void {
  const minCount = 2;
  const jaccardThreshold = 0.10;
  const charRatioThreshold3 = 0.20;
  const charRatioThreshold4 = 0.20;

  // Pass 1: 2-char names (Jaccard filter)
  // Note: original checked name.len != 6 (3 bytes * 2 chars)
  // We check actual character count instead of byte length to fix 4-byte CJK bug
  for (const [name, count] of candidates) {
    const charCount = Array.from(name).length;
    if (charCount !== 2 || count < minCount) continue;

    const chars = Array.from(name);
    const f1 = charFreq.get(chars[0]) || 0;
    const f2 = charFreq.get(chars[1]) || 0;
    const unionSize = f1 + f2 - count;
    if (unionSize === 0) continue;
    const jaccard = count / unionSize;
    if (jaccard < jaccardThreshold) continue;

    if (!result.has(name)) {
      result.set(name, 0);
    }
  }

  // Pass 2: 3-char names (min-character ratio filter)
  for (const [name, count] of candidates) {
    const charCount = Array.from(name).length;
    if (charCount !== 3 || count < minCount) continue;

    const minFreq = minCharFreq(name, charFreq);
    if (minFreq === null) continue;
    const charRatio = count / minFreq;
    if (charRatio < charRatioThreshold3) continue;

    if (!result.has(name)) {
      result.set(name, 0);
    }
  }

  // Pass 3: 4-char names (must have accepted 3-char prefix + min-character ratio)
  for (const [name, count] of candidates) {
    const charCount = Array.from(name).length;
    if (charCount !== 4 || count < minCount) continue;

    const chars = Array.from(name);
    const prefix = chars.slice(0, 3).join('');
    if (!result.has(prefix)) continue;

    const minFreq = minCharFreq(name, charFreq);
    if (minFreq === null) continue;
    const charRatio = count / minFreq;
    if (charRatio < charRatioThreshold4) continue;

    if (!result.has(name)) {
      result.set(name, 0);
    }
  }
}

export type NameSet = Map<string, number>;

export function buildNameSetFromContents(contents: string[]): NameSet {
  const result = new Map<string, number>();

  for (const content of contents) {
    if (content.length === 0) continue;

    const candidates = new Map<string, number>();
    const charFreq = new Map<string, number>();

    countCjkChars(content, charFreq);
    collectCandidates(content, candidates);
    addFilteredNames(candidates, charFreq, result);
  }

  // Assign colors (0-7) to each detected name
  let colorIdx = 0;
  for (const name of result.keys()) {
    result.set(name, colorIdx % 8);
    colorIdx++;
  }

  return result;
}

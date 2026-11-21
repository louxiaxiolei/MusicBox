// 音乐盒示例音源：Internet Archive（archive.org 上公开的音频，多为公有领域 / CC 授权）
// 用来演示插件格式，可以照着这个写自己的音源。

const axios = require('axios');

function pickArtist(creator) {
  if (!creator) return '未知';
  return Array.isArray(creator) ? creator.join(' / ') : String(creator);
}

module.exports = {
  platform: 'Internet Archive',
  version: '1.0.0',
  author: 'MusicBox',

  async search(keyword, page) {
    const q = encodeURIComponent('(' + keyword + ') AND mediatype:(audio)');
    const url = 'https://archive.org/advancedsearch.php?q=' + q +
      '&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=creator&rows=20&page=' + page + '&output=json';
    const res = await axios.get(url);
    const body = res.data && res.data.response;
    if (!body) throw new Error('archive.org 返回异常');
    const docs = body.docs || [];
    return {
      isEnd: page * 20 >= body.numFound,
      data: docs.map(function (d) {
        return {
          id: d.identifier,
          title: Array.isArray(d.title) ? d.title[0] : (d.title || d.identifier),
          artist: pickArtist(d.creator),
          album: 'Internet Archive',
          artwork: 'https://archive.org/services/img/' + d.identifier
        };
      })
    };
  },

  async getMediaSource(musicItem) {
    const res = await axios.get('https://archive.org/metadata/' + musicItem.id);
    const files = (res.data && res.data.files) || [];
    const audio = files.find(function (f) { return /\.mp3$/i.test(f.name); }) ||
                  files.find(function (f) { return /\.(m4a|ogg|flac|wav)$/i.test(f.name); });
    if (!audio) throw new Error('这个条目里没有可播放的音频文件');
    const path = audio.name.split('/').map(encodeURIComponent).join('/');
    return { url: 'https://archive.org/download/' + musicItem.id + '/' + path };
  }
};
